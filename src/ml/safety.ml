open Globals
open EvalValue
open EvalContext
open EvalEncode
open Common
open MacroApi
open Type
open Ast
open Globals

type safety_error = {
	se_msg : string;
	se_pos : pos;
}

type safety_context = {
	mutable sc_errors : safety_error list;
}

(**
	Terminates compiler process and prints user-friendly instructions about filing an issue in compiler repo.
*)
let fail ?msg hxpos mlpos =
	let msg =
		(Lexer.get_error_pos (Printf.sprintf "%s:%d:") hxpos) ^ ": "
		^ "Haxe-safety: " ^ (match msg with Some msg -> msg | _ -> "unexpected expression.") ^ "\n"
		^ "Please submit an issue to https://github.com/RealyUniqueName/Haxe-Safety/issues with expression example and following information:"
	in
	match mlpos with
		| (file, line, _, _) ->
			Printf.eprintf "%s\n" msg;
			Printf.eprintf "%s:%d\n" file line;
			assert false

let accessed_field_name access =
	match access with
		| FInstance (_, _, { cf_name = name }) -> name
		| FStatic (_, { cf_name = name }) -> name
		| FAnon { cf_name = name } -> name
		| FDynamic name -> name
		| FClosure (_, { cf_name = name }) -> name
		| FEnum (_, { ef_name = name }) -> name

(**
	Class to simplify collecting lists of local vars checked against `null`.
*)
class local_vars =
	object (self)
		(** Hashtbl to collect local vars which are checked against `null` and are not nulls. *)
		val mutable safe_locals = Hashtbl.create 100
		(**
			Check if local variable is guaranteed to not have a `null` value.
		*)
		method is_safe local_var =
			Hashtbl.mem safe_locals local_var.v_id
		(**
			Clear collected data
		*)
		method clear =
			Hashtbl.clear safe_locals
		(**
			This method should be called upon passing `if`.
			It collects locals checked against `null` and executes blocks of `if` and `else` with proper statuses of locals.
		*)
		method process_if expr (if_callback:expr->unit) (else_callback:expr->unit) =
			match expr.eexpr with
				| TIf (contidtion, if_body, else_body) -> ()
				| _ -> fail ~msg:"Expected TIf" expr.epos __POS__
	end

(**
	This is a base class is used to recursively check typed expressions for null-safety
*)
class virtual base_checker ctx =
	object (self)
	(**
		Entry point for checking a all expression in current type
	*)
	method virtual check : unit
	(**
		Register an error
	*)
	method error msg p =
		ctx.sc_errors <- { se_msg = msg; se_pos = p; } :: ctx.sc_errors
	(**
		Determines if we have a Null<T> which was not checked against `null` yet.
	*)
	method is_nullable_type t =
		match t with
			| TMono r ->
				(match !r with None -> false | Some t -> self#is_nullable_type t)
			| TAbstract ({ a_path = ([],"Null") }, [t]) ->
				true
			| TLazy f ->
				self#is_nullable_type (lazy_type f)
			| TType (t,tl) ->
				self#is_nullable_type (apply_params t.t_params tl t.t_type)
			| _ ->
				false
	(**
		Check if `e` is nullable even if the type is reported non-nullable.
		Haxe type system lies sometimes.
	*)
	method private is_nullable_expr e =
		match e.eexpr with
			| TConst TNull -> true
			| TParenthesis e -> self#is_nullable_expr e
			| TBlock exprs ->
				(match exprs with
					| [] -> false
					| _ -> self#is_nullable_expr (List.hd (List.rev exprs))
				)
			| TIf (condition, if_body, else_body) ->
				if self#is_nullable_expr if_body then
					true
				else
					(match else_body with
						| None -> false
						| Some else_body -> self#is_nullable_expr else_body
					)
			| _ -> self#is_nullable_type e.etype
	(**
		Recursively checks an expression
	*)
	method private check_expr e =
		match e.eexpr with
			| TConst _ -> ()
			| TLocal _ -> ()
			| TArray (arr, idx) -> self#check_array_access arr idx e.epos
			| TBinop (op, left_expr, right_expr) -> self#check_binop op left_expr right_expr e.epos
			| TField (target, access) -> self#check_field target access e.epos
			| TTypeExpr _ -> ()
			| TParenthesis e -> self#check_expr e
			| TObjectDecl _ -> ()
			| TArrayDecl _ -> ()
			| TCall (callee, args) -> self#check_call callee args
			| TNew ({ cl_constructor = Some { cf_expr = Some callee } }, _, args) -> self#check_call callee args
			| TNew (_, _, args) -> List.iter self#check_expr args
			| TUnop (_, _, expr) -> self#check_unop expr e.epos
			| TFunction fn -> self#check_expr fn.tf_expr
			| TVar (v, Some init_expr) -> self#check_var v init_expr e.epos
			| TVar (_, None) -> ()
			| TBlock exprs -> List.iter self#check_expr exprs
			| TFor _ -> ()
			| TIf _ -> ()
			| TWhile _ -> ()
			| TSwitch _ -> ()
			| TTry _ -> ()
			| TReturn _ -> ()
			| TBreak -> ()
			| TContinue -> ()
			| TThrow _ -> ()
			| TCast _ -> ()
			| TMeta _ -> ()
			| TEnumParameter _ -> ()
			| TEnumIndex _ -> ()
			| TIdent _ -> ()
	(**
		Check array access on nullable values or using nullable indexes
	*)
	method private check_array_access arr idx p =
		if self#is_nullable_expr arr then
			self#error "Cannot perform array access on nullable value." p;
		if self#is_nullable_expr idx then
			self#error "Cannot use nullable value as an index for array access." p;
		self#check_expr arr;
		self#check_expr idx
	(**
		Don't perform unsafe binary operations
	*)
	method private check_binop op left_expr right_expr p =
		(match op with
			| OpAssign ->
				if not (self#is_nullable_expr left_expr) && self#is_nullable_expr right_expr then
					self#error "Cannot assign nullable value to non-nullable acceptor." p
			| _->
				if self#is_nullable_expr left_expr || self#is_nullable_expr right_expr then
					self#error "Cannot perform binary operation on nullable value." p
		);
		self#check_expr left_expr;
		self#check_expr right_expr
	(**
		Don't perform unops on nullable values
	*)
	method private check_unop e p =
		if self#is_nullable_expr e then
			self#error "Cannot execute unary operation on nullable value." p;
		self#check_expr e
	(**
		Don't assign nullable value to non-nullable variable on var declaration
	*)
	method private check_var v e p =
		if self#is_nullable_expr e && not (self#is_nullable_type v.v_type) then
			self#error "Cannot assign nullable value to non-nullable variable." p;
		self#check_expr e
	(**
		Make sure nobody tries to access a field on a nullable value
	*)
	method private check_field target access p =
		if self#is_nullable_expr target then
			self#error ("Cannot access \"" ^ accessed_field_name access ^ "\" of a nullable value.") p
	(**
		Check calls: don't call a nullable value, dont' pass nulable values to non-nullable arguments
	*)
	method check_call callee args =
		if self#is_nullable_expr callee then
			self#error "Cannot call a nullable value." callee.epos;
		self#check_expr callee;
		List.iter self#check_expr args;
		match follow callee.etype with
			| TFun (types, _) ->
				let rec traverse args types =
					match (args, types) with
						| (a :: args, (arg_name, _, t) :: types) ->
							if (self#is_nullable_expr a) && not (self#is_nullable_type t) then begin
								let fn_name = match callee.eexpr with
									| TField (_, access) -> field_name access
									| TIdent fn_name -> fn_name
									| TLocal { v_name = fn_name } -> fn_name
									| _ -> ""
								in
								let fn_str = if fn_name = "" then "" else " of function \"" ^ fn_name ^ "\""
								and arg_str = if arg_name = "" then "" else " \" ^ arg_name ^ \"" in
								self#error ("Cannont pass nullable value to non-nullable argument" ^ arg_str ^ fn_str ^ ".") a.epos
							end;
							traverse args types
						| _ -> ()
				in
				traverse args types
			| _ -> ()
end

class class_checker cls ctx =
	object (self)
		inherit base_checker ctx
	(**
		Entry point for checking a class
	*)
	method check =
		let check_field f =
			Option.may self#check_expr f.cf_expr
		in
		Option.may self#check_expr cls.cl_init;
		(* Option.may (fun field -> Option.may self#check_expr field.cf_expr) cls.cl_constructor; *)
		List.iter check_field cls.cl_ordered_fields;
		List.iter check_field cls.cl_ordered_statics;
end

class plugin =
	object (self)
		val ctx = { sc_errors = [] }
	(**
		Plugin API: this method should be executed at initialization macro time
	*)
	method run () =
		let com = (get_ctx()).curapi.get_com() in
		add_typing_filter com (fun types ->
			(* let t = macro_timer ctx ["safety plugin"] in *)
			let rec traverse com_type =
				match com_type with
					| TEnumDecl enm -> ()
					| TTypeDecl typedef -> ()
					| TAbstractDecl abstr -> ()
					| TClassDecl { cl_path = ([], "Safety") } -> () (* Skip our own code *)
					| TClassDecl cls -> (new class_checker cls ctx)#check
			in
			List.iter traverse types;
			if not (raw_defined com "SAFETY_SILENT") then
				List.iter (fun err -> com.error err.se_msg err.se_pos) ctx.sc_errors;
			(* t() *)
		);
		(* This is because of vfun0 should return something *)
		vint32 (Int32.of_int 0)
	(**
		Plugin API: returns a list of all errors found during safety checks
	*)
	method get_errors () =
		let arr = Array.make (List.length ctx.sc_errors) vnull in
		let set_item idx msg p =
			let obj = encode_obj_s
				vnull
				[
					("msg", vstring (Rope.of_string msg));
					("pos", encode_pos p)
				]
			in
			Array.set arr idx obj
		in
		let rec traverse idx errors =
			match errors with
				| err :: errors ->
					set_item idx err.se_msg err.se_pos;
					traverse (idx + 1) errors
				| [] -> ()
		in
		traverse 0 ctx.sc_errors;
		(* VArray arr *)
		VArray (EvalArray.create arr)
end
;;

let api = new plugin in

EvalStdLib.StdContext.register [("run", vfun0 api#run); ("getErrors", vfun0 api#get_errors)]