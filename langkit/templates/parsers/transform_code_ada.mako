## vim: filetype=makoada

--  Start transform_code

${parser.parser.generate_code()}

if ${parser.pos_var} /= No_Token_Index then

   ## Create the transform wrapper node
   ${parser.res_var} := ${parser.get_type().name}
     (${parser.get_type().name}_Alloc.Alloc (Parser.Mem_Pool));
   ${parser.res_var}.Kind := ${parser.get_type().ada_kind_name};

   ## Compute and set the sloc range for this AST node. Reminders:
   ##   * start_pos the name for the position of the lexer before this parser
   ##     runs.
   ##   * parser.pos_var is the name for the position of the lexer
   ##     after this parser runs.
   ## If they are equal then we know that this parser consumed no token. As a
   ## result, the result must be a ghost node, i.e. with no token_end.
   ${parser.res_var}.Unit := Parser.Unit;
   ${parser.res_var}.Token_Start_Index := ${parser.start_pos};
   ${parser.res_var}.Token_End_Index :=
     (if ${parser.pos_var} = ${parser.start_pos}
      then No_Token_Index
      else ${parser.pos_var} - 1);

   % for field, arg in zip(parser.get_type().get_parse_fields(), args):
      ## Set children fields into the created node
      ${parser.res_var}.${field.name} :=
         % if field.type.is_ast_node:
            ${field.type.storage_type_name} (${arg});
         % else:
            ${arg};
         % endif
   % endfor

end if;

--  End transform_code
