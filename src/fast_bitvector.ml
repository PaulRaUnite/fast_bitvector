(* SPDX-License-Identifier: MPL-2.0
 * SPDX-FileCopyrightText: (c) 2025 Stefan Muenzel
 *)

let (=) = Int.equal

type t = Bytes.t

let failwithf s = Printf.ksprintf failwith s

module type Element = sig
  type t

  val bit_size : int
  val byte_size : int
  val shift : int

  val equal : t -> t -> bool

  val to_int : t -> int
  val of_int : int -> t

  val get : bytes -> int -> t
  val set : bytes -> int -> t -> unit

  val zero : t
  val one : t
  val minus_one : t

  val sub : t -> t -> t
  val shift_left : t -> int -> t
  val shift_right_logical : t -> int -> t

  val logand : t -> t -> t
  val logor : t -> t -> t
  val logxor : t -> t -> t
  val lognot : t -> t

  val count_set_bits : t -> int
end

module Element_32 = struct
  include Int32

  let bit_size = 32
  let byte_size = 4
  let shift = 5

  external get : bytes -> int -> t = "%caml_bytes_get32u"
  external set : bytes -> int -> t -> unit = "%caml_bytes_set32u"

  let set b i v = set b (i*byte_size) v
  let get b i = get b (i*byte_size)

  let count_set_bits = Popcount.count_set_bits_32
end

module Element_64 = struct
  include Int64

  let bit_size = 64
  let byte_size = 8
  let shift = 6

  external get : bytes -> int -> t = "%caml_bytes_get64u"
  external set : bytes -> int -> t -> unit = "%caml_bytes_set64u"

  let set b i v = set b (i*byte_size) v
  let get b i = get b (i*byte_size)

  let count_set_bits = Popcount.count_set_bits_64
end

module Element = (val
                   if Sys.word_size = 32
                    then (module Element_32 : Element)
                    else (module Element_64 : Element)
                 )

let length t =
  Element.get t 0
  |> Element.to_int

let max_length =
  ((Sys.max_string_length / Element.byte_size) - 1) * Element.bit_size

let [@inline always] total_words ~length =
  (length + Element.bit_size - 1) lsr Element.shift

let create ~len:new_length =
  if new_length > max_length
  then failwithf "length %d exceeds maximum length %d" new_length max_length;
  let total_data_words = (new_length + Element.bit_size - 1) / Element.bit_size in
  let total_words = total_data_words + 1 in
  let t = Bytes.init (total_words * Element.byte_size) (fun _ -> '\x00') in
  Element.set t 0 (Element.of_int new_length);
  assert (length t == new_length);
  t

let [@inline always] loop_set result value =
  let length = length result in
  let total_words = total_words ~length in
  for i = 1 to total_words do
    Element.set result i
      value
  done

let set_all t =
  loop_set t Element.minus_one

let clear_all t =
  loop_set t Element.zero

external (&&&) : bool -> bool -> bool = "%andint"

let [@inline always] foldop1 ~init ~f ~final a =
  let length = length a in
  let total_words = total_words ~length in
  let acc = ref init in
  for i = 1 to pred total_words do
    acc :=
      (f [@inlined hint])
        !acc
        (Element.get a i)
  done;
  let remaining = length land (Element.bit_size - 1) in
  let mask = Element.sub (Element.shift_left Element.one remaining) Element.one in
  (f [@inlined hint])
    !acc
    (final ~mask (Element.get a total_words))

let popcount t =
  foldop1 t 
    ~init:0
    ~f:(fun acc v -> acc + (Element.count_set_bits v))
    ~final:(fun ~mask a -> Element.logand mask a)

let is_empty t =
  foldop1 t
    ~init:true
    ~f:(fun acc v -> acc &&& (Element.equal v Element.zero))
    ~final:(fun ~mask a -> Element.logand mask a)

let is_full t =
  foldop1 t
    ~init:true
    ~f:(fun acc v -> acc &&& (Element.equal v Element.minus_one))
    ~final:(fun ~mask a -> Element.logor (Element.lognot mask) a)
    
module type Check = sig
  val index : t -> int -> unit

  val length2 : t -> t -> int
  val length3 : t -> t -> t -> int
end

module [@inline always] Ops(Check : Check) = struct
  let [@inline always] logop1 ~f a result =
    let length = Check.length2 a result in
    let total_words = total_words ~length in
    for i = 1 to total_words do
      Element.set result i
        (f
           (Element.get a i)
        )
    done;
    result

  let [@inline always] logop2 ~f a b result =
    let length = Check.length3 a b result in
    let total_words = total_words ~length in
    for i = 1 to total_words do
      Element.set result i
        (f
           (Element.get a i)
           (Element.get b i)
        )
    done;
    result

  let [@inline always] foldop2 ~init ~f ~final a b =
    let length = Check.length2 a b in
    let total_words = total_words ~length in
    let acc = ref init in
    for i = 1 to pred total_words do
      acc :=
        (f [@inlined hint])
          !acc
          (Element.get a i)
          (Element.get b i)
    done;
    let remaining = length land (Element.bit_size - 1) in
    let mask = Element.sub (Element.shift_left Element.one remaining) Element.one in
    (f [@inlined hint])
      !acc
      (final ~mask (Element.get a total_words))
      (final ~mask (Element.get b total_words))

  let [@inline always] get t i =
    Check.index t i;
    let index = 1 + (i lsr Element.shift) in
    let subindex = i land (Element.bit_size - 1) in
    let v = Element.get t index in
    Element.logand
      (Element.shift_right_logical v subindex)
      Element.one
    |> Element.to_int
    |> (Obj.magic : int -> bool)

  let [@inline always] set t i =
    Check.index t i;
    let index = 1 + (i lsr Element.shift) in
    let subindex = i land (Element.bit_size - 1) in
    let v = Element.get t index in
    let v' =
      Element.logor v (Element.shift_left Element.one subindex)
    in
    Element.set t index v'

  let [@inline always] set_to t i b =
    Check.index t i;
    let b = Element.of_int ((Obj.magic : bool -> int) b) in
    let index = 1 + (i lsr Element.shift) in
    let subindex = i land (Element.bit_size - 1) in
    let v = Element.get t index in
    let mask = Element.lognot (Element.shift_left Element.one subindex) in
    let v' =
      Element.logor
        (Element.logand v mask)
        (Element.shift_left b subindex)
    in
    Element.set t index v'

  let [@inline always] clear t i =
    Check.index t i;
    let index = 1 + (i lsr Element.shift) in
    let subindex = i land (Element.bit_size - 1) in
    let v = Element.get t index in
    let v' =
      Element.logand v (Element.lognot (Element.shift_left Element.one subindex))
    in
    Element.set t index v'

  let equal a b =
    foldop2 a b
      ~init:true
      ~f:(fun acc a b ->
          acc
          &&&
          (Element.equal Element.zero (Element.logxor a b))
        )
      ~final:(fun ~mask a -> Element.logand mask a)

  let not ~result a =
    logop1 ~f:Element.lognot a result

  let and_ ~result a b =
    logop2 ~f:Element.logand a b result

  let or_ ~result a b =
    logop2 ~f:Element.logor a b result

  let xor ~result a b =
    logop2 ~f:Element.logxor a b result

  module Set = struct
    let mem = get

    let intersect = and_
    let complement = not
    let symmetric_difference = xor

    let difference ~result a b =
      logop2 ~f:(fun a b ->
          Element.logand a (Element.lognot b)
        ) a b result
    
    let union = or_
  end

end

module Unsafe = Ops(struct
    let [@inline always] index _ _ = ()
    let [@inline always] length2 a _ = length a
    let [@inline always] length3 a _ _ = length a
  end)

include Ops(struct
    let [@inline always] index t i = assert (0 <= i && i < length t)

    let [@inline always] length2 a b =
      let la = length a in
      let lb = length b in
      assert (la = lb);
      la

    let [@inline always] length3 a b c =
      let la = length a in
      let lb = length b in
      let lc = length c in
      assert (la = lb);
      assert (la = lc);
      la
    end)

let equal a b =
  let la = length a in
  let lb = length b in
  la = lb && Unsafe.equal a b

let init new_length ~f =
  let t = create ~len:new_length in
  for i = 0 to new_length - 1 do
    Unsafe.set_to t i ((f [@inlined hint]) i);
  done;
  t

let create_full ~len =
  let t = create ~len in
  Unsafe.not ~result:t t

let copy t = Bytes.copy t

let append a b =
  let length_a = length a in
  let length_b = length b in
  let length = length_a + length_b in
  let t = create ~len:length in
  Bytes.blit a Element.byte_size t Element.byte_size ((length_a + 7) / 8);
  for i = 0 to pred length_b do
    Unsafe.set_to t (length_a + i) (Unsafe.get b i)
  done;
  t

let copy_bits src dst =
  let length = Int.min (length src) (length dst) in
  let byte_size = (length + 7) / 8 in
  if byte_size > 1 then (
    (* This assumes that bit direction in Element and bytes is the same, I guess? *)
    Bytes.blit src Element.byte_size dst Element.byte_size (byte_size - 1);
    for i = 8 * (length / 8) to pred length do
      Unsafe.set_to dst i (Unsafe.get src i)
    done)

let extend ~by v =
  let len = length v + by in
  let new_vec = create ~len in
  copy_bits v new_vec;
  new_vec

let extend_inplace ~by v =
  let prev_length = length v in
  let new_length = prev_length + by in
  let prev_capacity = 8 * Bytes.length v in
  let new_vec =
    if new_length <= prev_capacity then (
      Element.set v 0 (Element.of_int new_length);
      v)
    else extend ~by v
  in
  for i = prev_length to pred prev_capacity do
    Unsafe.set_to new_vec i false
  done;
  new_vec

let[@inline always] foldi ~init ~f t =
  let length = length t in
  let acc = ref init in
  for i = 0 to pred length do
    (* CR smuenzel: process word at a time *)
    acc := f !acc i (Unsafe.get t i)
  done;
  !acc

let fold ~init ~f v = foldi ~init ~f:(fun acc _i b -> f acc b) v

let map t ~f =
  (init [@inlined hint]) (length t) ~f:(fun i -> f (Unsafe.get t i))

let mapi t ~f =
  (init [@inlined hint]) (length t) ~f:(fun i -> f i (Unsafe.get t i))

open Sexplib0

module Big_endian' = struct
  type nonrec t = t

  let to_string t =
    let length = length t in
    (String.init [@inlined hint]) length (fun i ->
        if Unsafe.get t i
        then '1'
        else '0'
      )

  let of_string s =
    let length = String.length s in
    init length
      ~f:(fun i ->
          match String.unsafe_get s i with
          | '0' -> false
          | '1' -> true
          | other ->
            failwithf "invalid char '%c'" other
        )

  let sexp_of_t t =
    Sexp.List
      [ Sexp.Atom "BE"
      ; Sexp.Atom (to_string t)
      ]
end

module Little_endian' = struct
  type nonrec t = t

  let to_string t =
    let length = length t in
    (String.init [@inlined hint]) length (fun i ->
        if Unsafe.get t (length - (i + 1))
        then '1'
        else '0'
      )

  let of_string s =
    let length = String.length s in
    let result =
      init length
        ~f:(fun i ->
            match String.get s (length - (i + 1)) with
            | '0' -> false
            | '1' -> true
            | other ->
              failwithf "invalid char '%c'" other
          )
    in
    result

  let sexp_of_t t =
    Sexp.List
      [ Sexp.Atom "LE"
      ; Sexp.Atom (to_string t)
      ]
end

let t_of_sexp = function
  | Sexp.List
      [ Sexp.Atom "BE"
      ; Sexp.Atom s
      ] -> Big_endian'.of_string s
  | Sexp.List
      [ Sexp.Atom "LE"
      ; Sexp.Atom s
      ]
  | Sexp.Atom s ->
    Little_endian'.of_string s
  | other ->
    Sexp_conv.of_sexp_error "not a bitvector" other

let sexp_of_t = Little_endian'.sexp_of_t

module Big_endian = struct
  include Big_endian'

  let t_of_sexp = t_of_sexp
end

module Little_endian = struct
  include Little_endian'

  let t_of_sexp = t_of_sexp
end

let iteri ~f v = foldi ~init:() ~f:(fun _ i bit -> f i bit) v

let iter ~f v = iteri ~f:(fun _i b -> f b) v

let of_iter iter =
  let result = ref (create ~len:0) in
  iter (fun bit ->
      let i = length !result in
      let new_result = extend_inplace !result ~by:1 in
      set_to new_result i bit;
      result := new_result);
  !result

let to_seq v =
  let rec aux v i () =
    if length v > i then Seq.Cons (get v i, aux v (i + 1)) else Seq.Nil
  in
  aux v 0

let of_seq seq =
  Seq.fold_lefti
    (fun v i bit ->
      let new_result = extend_inplace v ~by:1 in
      set_to new_result i bit;
      (new_result))
    (create ~len:0) seq
