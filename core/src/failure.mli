(** Record identities scoped to one project run. *)
type id

val compare : id -> id -> int
val syntax : int -> id

(** Use the occurrence ordinal in the assembled observation. *)
val observation : int -> id

(** Identify the record for the invocation as a whole. *)
val policy : string -> id

type target = Vertex of Graph.Vertex_id.t | Edge of Graph.Edge_id.t

(** Identify the record for one product. [None] denotes the primary output. *)
val policy_product : invocation:string -> output:string option -> target -> id

type ('subject, 'detail) t = {
  id : id;
  subject : 'subject;
  detail : 'detail;
  causes : id list;
      (** The IDs of directly responsible records. An empty list marks a root. *)
}
