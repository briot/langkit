## vim: filetype=makoada

<%
   lexer = ctx.lexer
   termination = lexer.Termination.ada_name

   def token_actions(action_class):
       return sorted(tok.ada_name for tok in lexer.token_actions[action_class])

   with_symbol_actions = token_actions('WithSymbol')
   with_trivia_actions = token_actions('WithTrivia')
%>

with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;

with Interfaces;   use Interfaces;
with Interfaces.C; use Interfaces.C;

with System;

with GNAT.Byte_Order_Mark;

with GNATCOLL.Iconv;
with GNATCOLL.Mmap;    use GNATCOLL.Mmap;

with Langkit_Support.Symbols; use Langkit_Support.Symbols;
with Langkit_Support.Text;    use Langkit_Support.Text;

% if ctx.symbol_canonicalizer:
with ${ctx.symbol_canonicalizer.unit_fqn};
% endif

package body ${ada_lib_name}.Lexer is

   Quex_Leading_Characters : constant := 2;
   Quex_Trailing_Characters : constant := 1;
   Quex_Extra_Characters : constant :=
      Quex_Leading_Characters + Quex_Trailing_Characters;
   --  Quex requires its input buffer to have two leading reserved bytes and
   --  one trailing. These are not part of the true payload, but must be
   --  available anyway.

   use Token_Vectors, Trivia_Vectors, Integer_Vectors;

   type Quex_Token_Type is record
      Id                       : Unsigned_16;
      Text                     : System.Address;
      Text_Length              : size_t;
      Start_Line, End_Line     : Unsigned_32;
      Start_Column, End_Column : Unsigned_16;
      Offset                   : Unsigned_32;
   end record
      with Convention => C;
   type Interface_Token_Access is access all Quex_Token_Type;

   type Lexer_Type is new System.Address;

   procedure Decode_Buffer
     (Buffer, Charset : String;
      Read_BOM        : Boolean;
      Decoded_Buffer  : out Text_Access;
      Source_First    : out Positive;
      Source_Last     : out Natural);
   --  Allocate a Text_Type buffer, set it to Decoded_Buffer, decode Buffer
   --  into it using Charset and Source_First/Source_Last to the actual slice
   --  in Decoded_Buffer that hold the input source text. It is up to the
   --  caller to deallocate Decoded_Buffer when done with it.
   --
   --  Raise an Unknown_Charset exception if Charset is... unknown. Raise
   --  Invalid_Input if Buffer contains invalid byte sequences according to
   --  Charset.
   --
   --  Quex quirk: this actually allocates more than the actual buffer to keep
   --  Quex happy. The two first characters are set to null and there is an
   --  extra null character at the end of the buffer. See the Quex_*_Characters
   --  constants above.

   function Lexer_From_Buffer (Buffer  : System.Address;
                               Length  : size_t)
                               return Lexer_Type
      with Import        => True,
           Convention    => C,
           External_Name => "${capi.get_name("lexer_from_buffer")}";

   procedure Free_Lexer (Lexer : Lexer_Type)
      with Import        => True,
           Convention    => C,
           External_Name => "${capi.get_name("free_lexer")}";

   function Next_Token (Lexer : Lexer_Type;
                        Token : Interface_Token_Access) return int
      with Import        => True,
           Convention    => C,
           External_Name => "${capi.get_name("next_token")}";

   generic
      With_Trivia : Boolean;
   procedure Process_All_Tokens
     (Lexer       : Lexer_Type;
      TDH         : in out Token_Data_Handler;
      Diagnostics : in out Diagnostics_Vectors.Vector);

   ------------------------
   -- Process_All_Tokens --
   ------------------------

   procedure Process_All_Tokens
     (Lexer       : Lexer_Type;
      TDH         : in out Token_Data_Handler;
      Diagnostics : in out Diagnostics_Vectors.Vector)
   is

      Token                 : aliased Quex_Token_Type;
      Token_Id              : Token_Kind := ${termination};
      % if lexer.track_indent:
      Prev_Id               : Token_Kind := ${termination};
      % endif
      Symbol                : Symbol_Type;
      Continue              : Boolean := True;
      Last_Token_Was_Trivia : Boolean := False;

      ## Variables specific to indentation tracking
      % if lexer.track_indent:

      --  Stack of indentation levels. Used to emit the proper number of dedent
      --  tokens on dedent.
      Columns_Stack     : array (1 .. 128) of Column_Number := (others => 0);
      Columns_Stack_Len : Natural := 0;

      Ign_Layout_Level  : Integer := 0;
      --  Whether to ignore layout tokens or not. If 0, Ignore is off, if >0,
      --  ignore is on.

      function Get_Col return Column_Number
      is (if Columns_Stack_Len > 0
          then Columns_Stack (Columns_Stack_Len)
          else 1)
      with Inline;
      --  Get the current indent column in the stack

      % endif

      function Source_First return Positive is
        (Natural (Token.Offset) + TDH.Source_First - 1);
      --  Index in TDH.Source_Buffer for the first character corresponding to
      --  the current token.

      function Source_Last return Natural is
        (Source_First + Natural (Token.Text_Length) - 1);
      --  Likewise, for the last character

      function Sloc_Range return Source_Location_Range is
        ((Line_Number (Token.Start_Line),
          Line_Number (Token.End_Line),
          Column_Number (Token.Start_Column),
          Column_Number (Token.End_Column)));
      --  Create a sloc range value corresponding to Token

      procedure Prepare_For_Trivia
        with Inline;
      --  Append an entry for the current token in the Tokens_To_Trivias
      --  correspondence vector.

      ------------------------
      -- Prepare_For_Trivia --
      ------------------------

      procedure Prepare_For_Trivia is
      begin
         if With_Trivia then
            --  By default, the current token will have no trivia
            Append (TDH.Tokens_To_Trivias, Integer (No_Token_Index));

            --  Reset Last_Token_Was_Trivia so that new trivia is added to the
            --  current token.
            Last_Token_Was_Trivia := False;
         end if;
      end Prepare_For_Trivia;

   begin
      --  The first entry in the Tokens_To_Trivias map is for leading trivias
      Prepare_For_Trivia;

      while Continue loop

         --  Next_Token returns 0 for the last token, which will be our "null"
         --  token.

         Continue := Next_Token (Lexer, Token'Unrestricted_Access) /= 0;

         % if lexer.track_indent:
         --  Update the previous token id variable
         Prev_Id := Token_Id;
         % endif

         Token_Id := Token_Kind'Enum_Val (Token.Id);
         Symbol := null;

         case Token_Id is

         % if with_symbol_actions:
            ## Token id is part of the class of token types for which we want to
            ## internalize the text.
            when ${' | '.join(with_symbol_actions)} =>
               declare
                  Bounded_Text : Text_Type (1 .. Natural (Token.Text_Length))
                     with Address => Token.Text;

                  Symbol_Res : constant Symbolization_Result :=
                     % if ctx.symbol_canonicalizer:
                        ${ctx.symbol_canonicalizer.fqn} (Bounded_Text);
                     % else:
                        Create_Symbol (Bounded_Text);
                     % endif
               begin
                  if Symbol_Res.Success then
                     Symbol := Find (TDH.Symbols, Symbol_Res.Symbol);
                  else
                     Append (Diagnostics, Sloc_Range,
                             Symbol_Res.Error_Message);
                  end if;
               end;
         % endif

         % if with_trivia_actions:
            when ${' | '.join(with_trivia_actions)} =>
               if With_Trivia then
                  if Last_Token_Was_Trivia then
                     Last_Element (TDH.Trivias).all.Has_Next := True;
                  else
                     Last_Element (TDH.Tokens_To_Trivias).all :=
                        Last_Index (TDH.Trivias) + 1;
                  end if;

                  Append
                    (TDH.Trivias,
                     (Has_Next => False,
                      T        => (Kind         => Token_Id,
                                   Source_First => Source_First,
                                   Source_Last  => Source_Last,
                                   Symbol       => null,
                                   Sloc_Range   => Sloc_Range)));

                  Last_Token_Was_Trivia := True;
               end if;

               --  Whether or nottrivia is disabled, emit a diagnostic for
               --  lexing failures.

               if Token_Id = ${lexer.LexingFailure.ada_name} then
                  Append (Diagnostics, Sloc_Range,
                          "Invalid token, ignored");
               end if;

               goto Dont_Append;
         % endif

            ## Else, don't keep the text at all
            when others =>
               null;

         end case;

         % if not lexer.track_indent:
         --  Special case for the termination token: Quex yields inconsistent
         --  offsets/sizes. Make sure we get the end of the buffer so that the
         --  rest of our machinery (in particular source slices) works well
         --  with it.

         TDH.Tokens.Append
           ((Kind         => Token_Id,
             Source_First => (if Token_Id = ${termination}
                              then TDH.Source_Last + 1
                              else Source_First),
             Source_Last  => (if Token_Id = ${termination}
                              then TDH.Source_Last
                              else Source_Last),
             Symbol       => Symbol,
             Sloc_Range   => Sloc_Range));

         ##  This whole section is only emitted if the user chose to track
         ##  indentation in the lexer. It has complex machinery to emit
         ##  Indent/Dedent tokens, but only when in a zone of the code where
         ##  layout is not ignored.
         % else:

         --  If the token is termination, emit the missing dedent tokens
         if Token_Id = ${termination} then
            while Get_Col > 1 loop
               TDH.Tokens.Append
                 ((Kind         => ${lexer.Dedent.ada_name},
                   Source_First => TDH.Source_Last + 1,
                   Source_Last  => TDH.Source_Last,
                   Symbol       => null,
                   Sloc_Range   => Sloc_Range));
               Columns_Stack_Len := Columns_Stack_Len - 1;
            end loop;
         end if;

         <%
            end_ilayout_toks = (
               " | ".join(t.ada_name
               for t in lexer.tokens if t.end_ignore_layout)
            )
            start_ilayout_toks = (
               " | ".join(t.ada_name
               for t in lexer.tokens if t.start_ignore_layout)
            )
         %>

         --  If we're reading a token that triggers the end of layout ignore ..
         % if end_ilayout_toks:
         if Token_Id in ${end_ilayout_toks} then
            --  Decrement the ignore stack ..
            Ign_Layout_Level := Ign_Layout_Level - 1;
         end if;
         % endif

         --  If we don't ignore layout, and the token is the first on a new
         --  line, and it is not a newline token, then:
         if Ign_Layout_Level <= 0
            and then Prev_Id = ${lexer.Newline.ada_name}
            and then Token_Id /= ${lexer.Newline.ada_name}
         then
            declare
               T : Token_Data_Type :=
                 (Kind         => <>,
                  Source_First => Source_First + 1,
                  Source_Last  => Source_First,
                  Symbol       => null,
                  Sloc_Range   =>
                    (Sloc_Range.Start_Line, Sloc_Range.Start_Line,
                     Sloc_Range.Start_Column, Sloc_Range.Start_Column));
            begin
               if Sloc_Range.Start_Column < Get_Col then
                  --  Emit every necessary dedent token if the line is
                  -- dedented, and pop values from the stack.
                  while Sloc_Range.Start_Column < Get_Col loop
                     T.Kind := ${lexer.Dedent.ada_name};
                     TDH.Tokens.Append (T);
                     Columns_Stack_Len := Columns_Stack_Len - 1;
                  end loop;
               elsif Sloc_Range.Start_Column > Get_Col then
                  --  Emit a single indent token, and put the new value on the
                  --  indent stack.
                  T.Kind := ${lexer.Indent.ada_name};
                  TDH.Tokens.Append (T);
                  Columns_Stack_Len := Columns_Stack_Len + 1;
                  Columns_Stack (Columns_Stack_Len) := Sloc_Range.Start_Column;
               end if;
            end;

         end if;

         % if start_ilayout_toks:
         --  If we're reading a token that triggers the start of layout ignore,
         --  increment the ignore level.
         if Token_Id in ${start_ilayout_toks} then
            Ign_Layout_Level := Ign_Layout_Level + 1;
         end if;
         % endif

         --  If we're in ignore layout mode, we don't want to emit newline
         --  tokens either.
         if Token_Id /= ${lexer.Newline.ada_name}
            or else Ign_Layout_Level <= 0
         then
            TDH.Tokens.Append
              ((Kind         => Token_Id,
                Source_First => (if Token_Id = ${termination}
                                 then TDH.Source_Last + 1
                                 else Source_First),
                Source_Last  => (if Token_Id = ${termination}
                                 then TDH.Source_Last
                                 else Source_Last),
                Symbol       => Symbol,
                Sloc_Range   => Sloc_Range));
         end if;
         % endif

         Prepare_For_Trivia;

      % if lexer.token_actions['WithTrivia']:
         <<Dont_Append>>
      % endif
      end loop;

   end Process_All_Tokens;

   procedure Process_All_Tokens_With_Trivia is new Process_All_Tokens (True);
   procedure Process_All_Tokens_No_Trivia is new Process_All_Tokens (False);

   -----------------------
   -- Lex_From_Filename --
   -----------------------

   procedure Lex_From_Filename
     (Filename, Charset : String;
      Read_BOM          : Boolean;
      TDH               : in out Token_Data_Handler;
      Diagnostics       : in out Diagnostics_Vectors.Vector;
      With_Trivia       : Boolean)
   is
      --  The following call to Open_Read may fail with a Name_Error exception:
      --  just let it propagate to the caller as there is no resource to
      --  release yet here.

      File        : Mapped_File := Open_Read (Filename);

      Region      : Mapped_Region := Read (File);
      Buffer_Addr : constant System.Address := Data (Region).all'Address;

      Buffer      : String (1 .. Last (Region));
      for Buffer'Address use Buffer_Addr;

   begin
      begin
         Lex_From_Buffer (Buffer, Charset, Read_BOM, TDH, Diagnostics,
                          With_Trivia);
      exception
         when Unknown_Charset | Invalid_Input =>
            Free (Region);
            Close (File);
            raise;
      end;
      Free (Region);
      Close (File);
   end Lex_From_Filename;

   ---------------------
   -- Lex_From_Buffer --
   ---------------------

   procedure Lex_From_Buffer
     (Buffer, Charset : String;
      Read_BOM        : Boolean;
      TDH             : in out Token_Data_Handler;
      Diagnostics     : in out Diagnostics_Vectors.Vector;
      With_Trivia     : Boolean)
   is
      Decoded_Buffer : Text_Access;
      Source_First   : Positive;
      Source_Last    : Natural;
      Lexer          : Lexer_Type;
   begin
      Decode_Buffer (Buffer, Charset, Read_BOM, Decoded_Buffer, Source_First,
                     Source_Last);
      Lexer := Lexer_From_Buffer
        (Decoded_Buffer.all'Address,
         size_t (Source_Last - Source_First + 1));

      --  In the case we are reparsing an analysis unit, we want to get rid of
      --  the tokens from the old one.

      Reset (TDH, Decoded_Buffer, Source_First, Source_Last);

      if With_Trivia then
         Process_All_Tokens_With_Trivia (Lexer, TDH, Diagnostics);
      else
         Process_All_Tokens_No_Trivia (Lexer, TDH, Diagnostics);
      end if;
      Free_Lexer (Lexer);
   end Lex_From_Buffer;

   -------------------
   -- Decode_Buffer --
   -------------------

   procedure Decode_Buffer
     (Buffer, Charset : String;
      Read_BOM        : Boolean;
      Decoded_Buffer  : out Text_Access;
      Source_First    : out Positive;
      Source_Last     : out Natural)
   is
      use GNAT.Byte_Order_Mark;
      use GNATCOLL.Iconv;

      --  In the worst case, we have one character per input byte, so the
      --  following is supposed to be big enough.

      Result : Text_Access :=
         new Text_Type (1 .. Buffer'Length + Quex_Extra_Characters);
      State  : Iconv_T;
      Status : Iconv_Result;
      BOM    : BOM_Kind := Unknown;

      Input_Index, Output_Index : Positive;

      First_Output_Index : constant Positive :=
         1 + Quex_Leading_Characters * 4;
      --  Index of the first byte in Result at which Iconv must decode Buffer

      Output : Byte_Sequence (1 .. 4 * Buffer'Size);
      for Output'Address use Result.all'Address;
      --  Iconv works on mere strings, so this is a kind of a view conversion

   begin
      Decoded_Buffer := Result;
      Source_First := Result'First + Quex_Leading_Characters;

      --  If we have a byte order mark, it overrides the requested Charset

      Input_Index := Buffer'First;
      if Read_BOM then
         declare
            Len : Natural;
         begin
            GNAT.Byte_Order_Mark.Read_BOM (Buffer, Len, BOM);
            Input_Index := Input_Index + Len;
         end;
      end if;

      --  GNATCOLL.Iconv raises a Constraint_Error for empty strings: handle
      --  them here.

      if Input_Index > Buffer'Last then
         Source_Last := Source_First - 1;
         return;
      end if;

      --  Create the Iconv converter. We will notice unknown charsets here

      declare
         use System;

         To_Code : constant String :=
           (if Default_Bit_Order = Low_Order_First
            then UTF32LE
            else UTF32BE);

         BOM_Kind_To_Charset : constant
            array (UTF8_All .. UTF32_BE) of String_Access :=
           (UTF8_All => UTF8'Unrestricted_Access,
            UTF16_LE => UTF16LE'Unrestricted_Access,
            UTF16_BE => UTF16BE'Unrestricted_Access,
            UTF32_LE => UTF32LE'Unrestricted_Access,
            UTF32_BE => UTF32BE'Unrestricted_Access);

         Actual_Charset : constant String :=
           (if BOM in UTF8_All .. UTF32_BE
            then BOM_Kind_To_Charset (BOM).all
            else Charset);
      begin
         State := Iconv_Open (To_Code, Actual_Charset);
      exception
         when Unsupported_Conversion =>
            Free (Result);
            raise Unknown_Charset;
      end;

      --  Perform the conversion itself

      Output_Index := First_Output_Index;
      Iconv (State,
             Buffer, Input_Index,
             Output (Output_Index .. Output'Last), Output_Index,
             Status);
      Source_Last := (Output_Index - 1 - Output'First) / 4 + Result'First;

      --  Raise an error if the input was invalid

      case Status is
         when Invalid_Multibyte_Sequence | Incomplete_Multibyte_Sequence =>
            --  TODO??? It may be more helpful to actually perform lexing on an
            --  incomplete buffer. The user would get both a diagnostic for the
            --  charset error and a best-effort list of tokens.

            Free (Result);
            Iconv_Close (State);
            raise Invalid_Input;

         when Full_Buffer =>

            --  This is not supposed to happen: we allocated Result to be big
            --  enough in all cases.

            raise Program_Error;

         when Success =>
            null;
      end case;

      --  Clear the bytes we left for Quex

      declare
         Nul : constant Wide_Wide_Character := Wide_Wide_Character'Val (0);
      begin
         Result (1) := Nul;
         Result (2) := Nul;
         Result (Buffer'Length + 3) := Nul;
      end;

      Iconv_Close (State);
   end Decode_Buffer;

   Token_Kind_Names : constant array (Token_Kind) of String_Access := (
      % for tok in ctx.lexer.tokens:
          ${tok.ada_name} =>
             new String'("${tok.name}")
          % if (not loop.last):
              ,
          % endif
      % endfor
   );

   Token_Kind_To_Literals : constant array (Token_Kind) of String_Access := (
   <% already_seen_set = set() %>

   % for lit, tok in ctx.lexer.literals_map.items():
      % if tok.ada_name not in already_seen_set:
       ${tok.ada_name} => new String'("${lit}")
       <% already_seen_set.add(tok.ada_name) %>
           ,
      % endif
   % endfor
      others => new String'("")
   );

   ---------------------
   -- Token_Kind_Name --
   ---------------------

   function Token_Kind_Name (Token_Id : Token_Kind) return String is
     (Token_Kind_Names (Token_Id).all);

   ------------------------
   -- Token_Kind_Literal --
   ------------------------

   function Token_Kind_Literal (Token_Id : Token_Kind) return String is
     (Token_Kind_To_Literals (Token_Id).all);

   -----------------------
   -- Token_Error_Image --
   -----------------------

   function Token_Error_Image (Token_Id : Token_Kind) return String is
      Literal : constant String := Token_Kind_Literal (Token_Id);
   begin
      return (if Literal /= ""
              then "'" & Literal & "'"
              else Token_Kind_Name (Token_Id));
   end Token_Error_Image;

   ------------------
   -- Force_Symbol --
   ------------------

   function Force_Symbol
     (TDH : Token_Data_Handler;
      T   : in out Token_Data_Type) return Symbol_Type is
   begin
      if T.Symbol = null then
         declare
            Text   : Text_Type renames
               TDH.Source_Buffer (T.Source_First ..  T.Source_Last);
            Symbol : constant Symbolization_Result :=
               % if ctx.symbol_canonicalizer:
                  ${ctx.symbol_canonicalizer.fqn} (Text)
               % else:
                  Create_Symbol (Text)
               % endif
            ;
         begin
            --  This function is run as part of semantic analysis: there is
            --  currently no way to report errors from here, so just discard
            --  canonicalization issues here.
            if Symbol.Success then
               T.Symbol := Find (TDH.Symbols, Symbol.Symbol);
            end if;
         end;
      end if;
      return T.Symbol;
   end Force_Symbol;

end ${ada_lib_name}.Lexer;
