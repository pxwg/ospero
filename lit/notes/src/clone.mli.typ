#import "/reader/book.typ": card-source, chunk
#show: card-source

= 抽象克隆与有限积态射 <core:src:clone.mli>

本模块实现 @lawvere-theory-clone[Abstract Clone] 与 @lawvere-theory-dag[Lawvere 理论] 中的核心代数结构，为 @core:src:policy_wiring.mli[Policy_wiring] 提供与具体业务无关的纯函数组合底座，具体实现见 @core:src:clone.ml[clone.ml]。

`operation` 对应单个载体上的 $n$ 元运算 (`projection`、`bind`)，`morphism` 对应输出列表构成的有限积态射 (`tuple`、`identity`、`compose`)。

#chunk(id: <source-core-src-clone-mli>)[
  ```ocaml
  (** Operations and finite-product morphisms over one carrier.
      Implementations are expected to be pure and total; equality is extensional.
      Invalid arities and incompatible dimensions raise [Invalid_argument]. *)

  (** An n-input, single-output operation. *)
  type 'a operation

  (** An m-input, n-output tuple of operations. *)
  type 'a morphism

  (** Declare a generator without executing it. *)
  val operation : int -> ('a list -> 'a) -> 'a operation

  val arity : 'a operation -> int

  (** Evaluate an operation on exactly its declared number of inputs. *)
  val run : 'a operation -> 'a list -> 'a

  (** Zero-based projection in the given input context. *)
  val projection : int -> int -> 'a operation

  (** All outputs must share the explicit input arity.
      An empty tuple retains its input arity and has zero outputs.
      Each output position is evaluated once, in list order; repeated operations
      are not automatically shared. *)
  val tuple : int -> 'a operation list -> 'a morphism

  val source : 'a morphism -> int
  val target : 'a morphism -> int

  (** Substitute the morphism's outputs into the operation's ordered ports.
      Each application evaluates the substitution morphism once, then runs the
      outer operation on that intermediate tuple. *)
  val bind : 'a operation -> 'a morphism -> 'a operation

  (** The tuple of projections, implemented by passing through the input tuple. *)
  val identity : int -> 'a morphism

  (** [compose ~after ~before] denotes componentwise substitution.
      Each application evaluates [before] once, then [after] on the shared
      intermediate tuple, including when [after] has zero outputs. *)
  val compose :
    after:'a morphism -> before:'a morphism -> 'a morphism

  (** Evaluate a morphism on exactly its source number of inputs.
      Intermediate values are shared within composition, not cached across
      separate applications. *)
  val apply : 'a morphism -> 'a list -> 'a list
  ```
]

#chunk(id: <file-core-src-clone-mli>, target: "core/src/clone.mli")[
  ```ocaml
  <<source-core-src-clone-mli>>
  ```
]
