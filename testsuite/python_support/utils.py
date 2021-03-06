from __future__ import absolute_import, division, print_function

import os
import shutil
import subprocess
import sys

from langkit.compile_context import CompileCtx
from langkit.compiled_types import CompiledTypeMetaclass, create_builtin_types
from langkit.diagnostics import DiagnosticError, WarningSet
from langkit.dsl import _StructMetaclass, _ASTNodeMetaclass, _EnumNodeMetaclass
from langkit.expressions import Entity, Self
from langkit.libmanage import ManageScript
from langkit.utils import reset_memoized


default_warning_set = WarningSet()

# We don't want to be forced to provide dummy docs for public properties in
# testcases.
default_warning_set.disable(WarningSet.undocumented_public_properties)

pretty_print = bool(int(os.environ.get('LANGKIT_PRETTY_PRINT', '0')))

project_template = """
with "libfoolang";

project Gen is
    for Languages use ("Ada");
    for Source_Dirs use (".");
    for Object_Dir use "obj";
    for Main use ("{main_source}");

    package Builder is
        for Executable ("{main_source}") use "main";
    end Builder;

    package Compiler is
        for Default_Switches ("Ada") use
          ("-g", "-O0", "-gnata", "-gnatwae", "-gnatyg");
    end Compiler;
end Gen;
"""


def prepare_context(grammar, lexer=None, warning_set=default_warning_set):
    """
    Create a compile context and prepare the build directory for code
    generation.

    :param langkit.parsers.Grammar grammar: The language grammar to use for
        this context.

    :param langkit.lexer.Lexer lexer: The language lexer to use for this
        context.

    :param WarningSet warning_set: Set of warnings to emit.
    """

    if lexer is None:
        from lexer_example import foo_lexer
        lexer = foo_lexer

    # Have a clean build directory
    if os.path.exists('build'):
        shutil.rmtree('build')
    os.mkdir('build')

    # Try to emit code
    ctx = CompileCtx(lang_name='Foo',
                     lexer=lexer,
                     grammar=grammar)
    ctx.warnings = warning_set
    ctx.pretty_print = pretty_print

    return ctx


def emit_and_print_errors(grammar, lexer=None,
                          warning_set=default_warning_set):
    """
    Compile and emit code for CTX. Return whether this was successful.

    :param langkit.parsers.Grammar grammar_fn: The language grammar to use.

    :param langkit.lexer.Lexer lexer: The lexer to use along with the grammar.
        Use `lexer_example.foo_lexer` if left to None.

    :param WarningSet warning_set: Set of warnings to emit.

    :rtype: bool
    """

    if lexer is None:
        from lexer_example import foo_lexer
        lexer = foo_lexer

    try:
        ctx = prepare_context(grammar, lexer, warning_set)
        ctx.emit('build', generate_lexer=False)
        # ... and tell about how it went
    except DiagnosticError:
        # If there is a diagnostic error, don't say anything, the diagnostics
        # are enough.
        return False
    else:
        print('Code generation was successful')
        return True
    finally:
        reset_langkit()


def build(grammar, lexer=None, warning_set=default_warning_set):
    """
    Shortcut for `build_and_run` to only build.
    """
    build_and_run(grammar, lexer=lexer, warning_set=warning_set)


def build_and_run(grammar, py_script=None, ada_main=None, lexer=None,
                  warning_set=default_warning_set, properties_logging=False):
    """
    Compile and emit code for `ctx` and build the generated library. Then, if
    `py_script` is not None, run it with this library available. If `ada_main`
    is not None, build it and run it, too.

    An exception is raised if any step fails (the script must return code 0).

    :param langkit.lexer.Lexer lexer: The lexer to use along with the grammar.
        See emit_and_print_errors.
    :param WarningSet warning_set: Set of warnings to emit.
    :param bool properties_logging: Whether to enable properties logging in
        code generation.
    """

    if lexer is None:
        from lexer_example import foo_lexer
        lexer = foo_lexer

    ctx = prepare_context(grammar, lexer, warning_set)

    class Manage(ManageScript):
        def create_context(self, args):
            return ctx

    m = Manage(override_lang_source_dir=False)

    extensions_dir = os.path.abspath('extensions')
    if os.path.isdir(extensions_dir):
        ctx.extensions_dir = extensions_dir

    # First build the library. Forward all test.py's arguments to the libmanage
    # call so that manual testcase runs can pass "-g", for instance.
    argv = sys.argv[1:] + ['--full-error-traces', '-vnone', 'make']
    for w in WarningSet.available_warnings:
        argv.append('-{}{}'.format('W' if w in warning_set else 'w', w.name))
    if properties_logging:
        argv.append('--enable-properties-logging')
    if pretty_print:
        argv.append('--pretty-print')
    m.run(argv)

    # Flush stdout and stderr, so that diagnostics appear deterministically
    # before the script/program output.
    sys.stdout.flush()
    sys.stderr.flush()

    # Write a "setenv" script to make developper investigation convenient
    with open('setenv.sh', 'w') as f:
        m.write_setenv(f)

    env = m.derived_env()

    def run(*argv):
        subprocess.check_call(argv, env=env)

    if py_script is not None:
        # Run the Python script. Note that in order to use the generated
        # library, we have to use the special Python interpreter the testsuite
        # provides us. See the corresponding code in
        # testuite_support/python_driver.py.
        python_interpreter = os.environ['PYTHON_INTERPRETER']
        run(python_interpreter, py_script)

    if ada_main is not None:
        # Generate a project file to build the given Ada main and then run the
        # program.
        with open('gen.gpr', 'w') as f:
            f.write(project_template.format(main_source=ada_main))
        run('gprbuild', '-Pgen', '-q', '-p',
            '-XLIBRARY_TYPE=relocatable', '-XXMLADA_BUILD=relocatable')
        run(os.path.join('obj', 'main'))


def reset_langkit():
    """
    Reset global state in Langkit.

    TODO: this is a hack to workaround another hack. At some point in the
    future, we should get rid of this global state in Langkit.
    """
    CompiledTypeMetaclass.root_grammar_class = None
    CompiledTypeMetaclass.astnode_types = []
    CompiledTypeMetaclass.struct_types = []
    CompiledTypeMetaclass.env_metadata = None
    CompiledTypeMetaclass.entity_info = None
    Self.unfreeze()
    Entity.unfreeze()

    CompiledTypeMetaclass.type_dict.clear()
    create_builtin_types()

    _StructMetaclass.reset()
    _ASTNodeMetaclass.reset()
    _EnumNodeMetaclass.reset()

    reset_memoized()
