%%  
%%  Copyright 2013, Andreas Stenius <kaos@astekk.se>
%%  
%%   Licensed under the Apache License, Version 2.0 (the "License");
%%   you may not use this file except in compliance with the License.
%%   You may obtain a copy of the License at
%%  
%%     http://www.apache.org/licenses/LICENSE-2.0
%%  
%%   Unless required by applicable law or agreed to in writing, software
%%   distributed under the License is distributed on an "AS IS" BASIS,
%%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%   See the License for the specific language governing permissions and
%%   limitations under the License.
%%  

-module(ecapnp_ref).
-author("Andreas Stenius <kaos@astekk.se>").

-export([get/3, get/4, 
         read_struct_data/3, read_struct_ptr/2,
         read_struct_data/4, read_struct_ptr/3,
         read_list/1, read_text/1, read_data/1,
         read_list/2, read_text/2, read_data/2,
         follow_far/1]).

-include("ecapnp.hrl").


%% ===================================================================
%% API functions
%% ===================================================================

get(SegmentId, Pos, Data) when is_pid(Data) ->
    get(SegmentId, Pos, Data, true).

get(SegmentId, Pos, Data, FollowFar) when is_pid(Data) ->
    read_segment(SegmentId, Pos,
                 ecapnp_data:get_segment(SegmentId, Pos, 1, Data),
                 Data, FollowFar).

read_struct_data(Align, Len, Ref) ->
    read_struct_data(Align, Len, Ref, <<0:Len/integer>>).
read_struct_data(_, Len, #ref{ kind=null }, Default)
  when Len == size(Default) -> Default;
read_struct_data(Align, Len,
                 #ref{ kind=#struct_ref{ dsize=DSize }}=Ref,
                 Default) ->
    if Align + Len < DSize * 64 ->
            <<_:Align/bits, Value:Len/bits, _/bits>>
                = get_segment(Ref, 1 + ((Align + Len - 1) div 64)),
            Value;
       true -> Default
    end.

read_struct_ptr(Idx, Ref) -> read_struct_ptr(Idx, Ref, #ref{}).
read_struct_ptr(_, #ref{ kind=null }, Default) -> Default;
read_struct_ptr(Idx, #ref{ segment=SegmentId, pos=Pos,
                           offset=Offset, data=Data,
                           kind=#struct_ref{
                                   dsize=DSize, psize=PSize } },
                Default) ->
    if Idx >= 0 andalso Idx < PSize ->
            get(SegmentId, Pos + 1 + Offset + DSize + Idx, Data);
       true -> Default
    end.

read_list(Ref) -> read_list(Ref, []).
read_list(#ref{ kind=null }, Default) -> Default;
read_list(#ref{ kind=#list_ref{ count=0 } }, Default) -> Default;
read_list(#ref{ segment=SegmentId, pos=Pos, offset=Offset, data=Data,
                kind=#list_ref{ size=Size, count=Count } }, _) ->
    TagOffset = Pos + 1 + Offset,
    if Size == inlineComposite ->
            #ref{ offset=Len }=Tag = get(SegmentId, TagOffset, Data),
            [Tag#ref{ pos=-1, offset=O }
             || O <- lists:seq(TagOffset + 1,
                               TagOffset + Count,
                               Count div Len)];
       Size == pointer ->
            List = ecapnp_data:get_segment(
                     SegmentId, TagOffset, Count, Data),
            [read_segment(SegmentId, TagOffset + I,
                          binary_part(List, I, 8),
                          Data, true)
             || I <- lists:seq(0, (Count - 1) * 8, 8)];
       Size == empty ->
            lists:duplicate(Count, <<>>);
       true ->
            ElementSize = list_element_size(Size),
            List = ecapnp_data:get_segment(
                     SegmentId, TagOffset,
                     1 + ((ElementSize * Count - 1) div 64),
                     Data),
            read_list_elements(ElementSize, List, Count, [])
    end.

read_text(Ref) -> read_text(Ref, <<>>).
read_text(#ref{ kind=null }, Default) -> Default;
read_text(#ref{ kind=#list_ref{ count=0 } }, Default) -> Default;
read_text(#ref{ kind=#list_ref{ size=byte, count=Count } }=Ref, _) ->
    binary_part(get_segment(Ref, 1 + ((Count - 2) div 8)), 0, Count - 1).

read_data(Ref) -> read_data(Ref, <<>>).
read_data(#ref{ kind=null }, Default) -> Default;
read_data(#ref{ kind=#list_ref{ count=0 } }, Default) -> Default;
read_data(#ref{ kind=#list_ref{ size=byte, count=Count } }=Ref, _) ->
    binary_part(get_segment(Ref, 1 + ((Count - 1) div 8)), 0, Count).

follow_far(#ref{ offset=Offset, data=Data,
                 kind=#far_ref{ segment=SegmentId, double_far=Double } }) ->
    Pad = get(SegmentId, Offset, Data, false),
    if Double ->
            Tag = get(SegmentId, Offset + 1, Data, false),
            Tag#ref{ segment=(Pad#ref.kind)#far_ref.segment,
                     pos=-1, offset=Pad#ref.offset };
       true -> Pad
    end.


%% ===================================================================
%% internal functions
%% ===================================================================

ptr_type(0, 0) -> null;
ptr_type(Offset, _) -> 
    ptr_type(Offset band 3).

ptr_type(0) -> struct;
ptr_type(1) -> list;
ptr_type(2) -> far_ptr;
ptr_type(3) -> reserved_ptr_type.

list_element_size(0) -> empty;
list_element_size(1) -> bit;
list_element_size(2) -> byte;
list_element_size(3) -> twoBytes;
list_element_size(4) -> fourBytes;
list_element_size(5) -> eightBytes;
list_element_size(6) -> pointer;
list_element_size(7) -> inlineComposite;
list_element_size(empty) -> 0;
list_element_size(bit) -> 1;
list_element_size(byte) -> 8;
list_element_size(twoBytes) -> 16;
list_element_size(fourBytes) -> 32;
list_element_size(eightBytes) -> 64;
list_element_size(inlineComposite) -> undefined.

get_segment(#ref{ segment=SegmentId, pos=Pos,
                  offset=Offset, data=Data }, Len) ->
    ecapnp_data:get_segment(SegmentId, Pos + 1 + Offset, Len, Data).

read_segment(SegmentId, Pos, Segment, Data, FollowFar) ->
    Ref = read_ref(Segment),
    case {FollowFar, Ref#ref.kind} of
        {true, #far_ref{}} -> follow_far(Ref#ref{ data=Data });
        _ -> Ref#ref{ segment=SegmentId, pos=Pos, data=Data }
    end.

read_ref(Segment) ->
    <<OffsetAndKind:32/integer-signed-little,
      Size:32/integer-little>> = Segment,
    case ptr_type(OffsetAndKind, Size) of
        null -> #ref{};
        struct ->
            #ref{ offset=OffsetAndKind bsr 2,
                  kind=#struct_ref{
                          dsize=Size band 16#ffff,
                          psize=Size bsr 16 }};
        list ->
            #ref{ offset=OffsetAndKind bsr 2,
                  kind=#list_ref{
                          size=list_element_size(Size band 7),
                          count=Size bsr 3 }};
        far_ptr ->
            #ref{ offset=OffsetAndKind bsr 3,
                  kind=#far_ref{
                          segment=Size,
                          double_far=OffsetAndKind band 4 > 0
                         }}
    end.

read_list_elements(_, _, 0, Acc) -> lists:reverse(Acc);
read_list_elements(1, <<Byte:1/bytes, Rest/binary>>, Count, Acc) ->
    read_list_element_bits(Byte, 7, Count, Rest, Acc);
read_list_elements(Size, List, Count, Acc) ->
    <<Elem:Size/bits, Rest/bits>> = List,
    read_list_elements(Size, Rest, Count - 1, [Elem|Acc]).

%% contrived routine to read bits off from a bit stream that is hard
%% coded big endian.. gnnggn!
read_list_element_bits(_, _, 0, _, Acc) -> lists:reverse(Acc);
read_list_element_bits(_, -1, Count, Rest, Acc) ->
    read_list_elements(1, Rest, Count, Acc);
read_list_element_bits(Bits, Left, Count, Rest, Acc) ->
    <<Next:Left/bits, Bit:1/bits>> = Bits,
    read_list_element_bits(Next, Left - 1, Count - 1, Rest, [Bit|Acc]).
