## vim: filetype=makoada

${expr.domain.render_pre()}
${expr.logic_var_expr.render_pre()}

declare
   Dom : ${expr.domain.type.name()} := ${expr.domain.render_expr()};
   A   : Eq_Node.Raw_Member_Array (1 .. Length (Dom));
begin
   for J in 0 .. Length (Dom) - 1 loop
      A (J + 1) := (
         % if expr.domain.static_type.element_type().is_entity_type:
            Get (Dom, J)
         % else:
            (El => Get (Dom, J), others => <>)
         % endif
      );
   end loop;

   ${expr.result_var.name} := Member (${expr.logic_var_expr.render_expr()}, A);

   ## Below, the call to Dec_Ref is here because:
   ##
   ## 1. Dom has an ownership share for each of its elements.
   ## 2. The call to member is borrowing this ownership share only for the time
   ##    of the call.
   ## 3. Calls to Get create ownership shares.

   for J in 1 .. Length (Dom) loop
      Dec_Ref (A (J));
   end loop;
end;