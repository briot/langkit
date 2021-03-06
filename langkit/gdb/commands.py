from __future__ import absolute_import, division, print_function

from collections import namedtuple
from functools import partial
from StringIO import StringIO
import sys

import gdb

from langkit.gdb.control_flow import go_next, go_out, go_step_inside
from langkit.gdb.debug_info import DSLLocation, ExprStart, Scope
from langkit.gdb.utils import expr_repr, name_repr, prop_repr
from langkit.utils import no_colors


def get_input(prompt):
    """
    Wrapper around raw_input/input depending on the Python version.
    """
    input_fn = input if sys.version_info.major > 2 else raw_input
    return input_fn(prompt)


class BaseCommand(gdb.Command):
    """
    Factorize common code for our commands.
    """

    def __init__(self, context, basename, command_class,
                 completer_class=gdb.COMPLETE_NONE):
        kwargs = {'name': '{}{}'.format(context.prefix, basename),
                  'command_class': command_class}
        if completer_class is not None:
            kwargs['completer_class'] = completer_class
        super(BaseCommand, self).__init__(**kwargs)
        self.context = context


class StateCommand(BaseCommand):
    """Display the state of the currently running property.

This command may be followed by a "/X" flag, where X is one or several of:

    * f: display the full image of values (no ellipsis);
    * s: to print the name of the Ada variables that hold DSL values.

There is one optional argument: a variable name. If specified, this command
only displays information for this variable.
"""

    def __init__(self, context):
        super(StateCommand, self).__init__(context, 'state', gdb.COMMAND_DATA)

    def invoke(self, arg, from_tty):
        args = arg.split()
        flags = set()
        var_name = None

        # Get flags, if any
        if args and args[0].startswith('/'):
            flags = set(args.pop(0)[1:])
            invalid_flags = flags.difference('sf')
            if invalid_flags:
                print('Invalid flags: {}'.format(', '.join(
                    invalid_flags
                )))
                return

        # Get the variable name, if any
        if args:
            var_name = args.pop(0)

        if args:
            print('Invalid extra arguments: {}'.format(' '.join(args)))

        StatePrinter(self.context,
                     with_ellipsis='f' not in flags,
                     with_locs='s' in flags,
                     var_name=var_name).run()


class StatePrinter(object):
    """
    Helper class to embed code to display the state of the currently running
    property.
    """

    ellipsis_limit = 50

    def __init__(self, context, with_ellipsis=True, with_locs=False,
                 var_name=None):
        self.context = context

        self.frame = gdb.selected_frame()
        self.state = self.context.decode_state(self.frame)

        self.with_ellipsis = with_ellipsis
        self.with_locs = with_locs
        self.var_name = var_name
        self.sio = StringIO()

    def _render(self):
        """
        Internal render method for the state printer.
        """

        # We rebind print to print to our StringIO instance for the scope of
        # this method.
        prn = partial(print, file=self.sio)

        def print_binding(print_fn, b):
            print_fn('{}{} = {}'.format(
                name_repr(b),
                self.loc_image(b.gen_name),
                self.value_image(b.gen_name)
            ))

        if self.state is None:
            prn('Selected frame is not in a property.')
            return

        # If we are asked to display only one variable, look for it, print it,
        # and stop there.
        if self.var_name:
            for scope_state in self.state.scopes:
                for b in scope_state.bindings:
                    if b.dsl_name == self.var_name:
                        print_binding(prn, b)
                        return
            prn('No binding called {}'.format(self.var_name))
            return

        prn('Running {}'.format(prop_repr(self.state.property)))
        if self.state.property.dsl_sloc:
            prn('from {}'.format(self.state.property.dsl_sloc))

        if self.state.in_memoization_lookup:
            prn('About to return a memoized result...')

        for scope_state in self.state.scopes:
            is_first = [True]

            def print_info(strn):
                if is_first[0]:
                    prn('')
                    is_first[0] = False
                prn(strn)

            for b in scope_state.bindings:
                print_binding(print_info, b)

            done_exprs, last_started = scope_state.sorted_expressions()

            for e in done_exprs:
                print_info('{}{} -> {}'.format(
                    expr_repr(e),
                    self.loc_image(e.result_var),
                    self.value_image(e.result_var)
                ))

            if last_started:
                print_info('Currently evaluating {}'.format(
                    expr_repr(last_started)
                ))
                if last_started.dsl_sloc:
                    print_info('from {}'.format(last_started.dsl_sloc))

    def run(self):
        """
        Output the state to stdout.
        """
        self._render()
        print(self.sio.getvalue())

    def render(self):
        """
        Return the state as a string.

        :rtype: str
        """
        with no_colors():
            self._render()
        return self.sio.getvalue()

    def loc_image(self, var_name):
        """
        If `self.with_locs`, return the name of the Ada variable that holds the
        DSL value.

        :rtype: str
        """
        return ' ({})'.format(var_name) if self.with_locs else ''

    def value_image(self, var_name):
        """
        Return the image of the value contained in the `var_name` variable.

        :rtype: str
        """
        # Switching to lower-case is required since GDB ignores case
        # insentivity for Ada from the Python API.
        value = str(self.frame.read_var(var_name.lower()))
        if self.with_ellipsis and len(value) > self.ellipsis_limit:
            value = '{}...'.format(value[:self.ellipsis_limit])
        return value


class BreakCommand(BaseCommand):
    """Put a breakpoint on a property. One of the following forms is allowed:

    * A case-insensitive property qualified name; for instance::
          break MyNode.p_property

    * A DSL source location; for instance, in spec.py, line 128::
          break spec.py:128

In both cases, one can pass an expression to make the breakpoint conditional.
For instance::

    break MyNode.p_property if $match("<Node XXX>", self)
"""

    def __init__(self, context):
        super(BreakCommand, self).__init__(context, 'break',
                                           gdb.COMMAND_BREAKPOINTS, None)

    def complete(self, text, word):
        """
        Try to complete `word`.

        Assuming `word` is the start of a property qualified name, return all
        possible completions. This is case insensitive, for user convenience.
        """
        prefix = word.lower()
        result = [prop.name for prop in self.context.debug_info.properties
                  if prop.name.lower().startswith(prefix)]

        # If the users didn't ask for a special property, don't suggest special
        # properties, as they are usually just noise for them.
        if not prefix.startswith('['):
            result = [n for n in result if not n.startswith('[')]

        return result

    def invoke(self, arg, from_tty):
        argv = arg.strip().split(None, 2)

        spec = None
        cond = None

        if len(argv) == 0:
            print('Breakpoint specification missing')
            return

        elif len(argv) == 1:
            spec,  = argv

        elif len(argv) == 3:
            spec, if_kwd, cond = argv
            if if_kwd != 'if':
                print('Invalid arguments (second arg should be "if")')
                return

        else:
            print('Invalid number of arguments')
            return

        bp = (self.break_on_dsl_sloc(spec)
              if ':' in spec else
              self.break_on_property(spec))
        if cond:
            try:
                bp.condition = cond
            except gdb.error as exc:
                print(exc)
                return

    def break_on_property(self, qualname):
        """
        Try to put a breakpoint on a property whose qualified name is
        `qualname`. Display a message for the user if that is not possible.
        """
        lower_prop = qualname.lower()

        for prop in self.context.debug_info.properties:
            if prop.name.lower() == lower_prop:
                break
        else:
            print('No such property: {}'.format(qualname))
            return

        if prop.body_start is None:
            print('Cannot break on {}: it has no code'.format(prop.name))
            return

        # Break on the first line of the property's first inner scope so that
        # we skip the prologue (all variable declarations).
        return gdb.Breakpoint('{}:{}'.format(self.context.debug_info.filename,
                                             prop.body_start))

    def break_on_dsl_sloc(self, dsl_sloc):
        """
        Try to put a breakpoint on code that maps to the given DSL source
        location. Display a message for the user if that is not possible.
        """
        dsl_sloc = DSLLocation.parse(dsl_sloc)

        Match = namedtuple('Match', 'prop dsl_sloc line_no')
        matches = []

        def process_scope(prop, scope):
            for e in scope.events:
                if isinstance(e, Scope):
                    process_scope(prop, e)
                elif (isinstance(e, ExprStart)
                      and e.dsl_sloc
                      and e.dsl_sloc.matches(dsl_sloc)):
                    matches.append(Match(prop, e.dsl_sloc, e.line_no))

        for prop in self.context.debug_info.properties:
            process_scope(prop, prop)

        if not matches:
            print('No match for {}'.format(dsl_sloc))
            return

        elif len(matches) == 1:
            m,  = matches

        else:
            print('Multiple matches for {}:'.format(dsl_sloc))

            def idx_fmt(i):
                return '[{}] '.format(i)

            idx_width = len(idx_fmt(len(matches)))
            for i, m in enumerate(matches, 1):
                print('{}In {}, {}'.format(
                    idx_fmt(i).rjust(idx_width),
                    m.prop.name, m.dsl_sloc
                ))
                print('{}at {}:{}'.format(' ' * idx_width,
                                          self.context.debug_info.filename,
                                          m.line_no))

            print('Please chose one of the above locations [default=1]:')
            try:
                choice = get_input('> ')
            except EOFError:
                print('Aborting: no breakpoint created')
                return

            if not choice:
                choice = 1
            else:
                try:
                    choice = int(choice)
                except ValueError:
                    print('Invalid index choice: {}'.format(choice))
                    return

                if choice < 1 or choice > len(matches):
                    print('Choice must be in range {}-{}'.format(
                        1, len(matches)
                    ))
                    return

            m = matches[choice]

        return gdb.Breakpoint('{}:{}'.format(
            self.context.debug_info.filename, m.line_no
        ))


class NextCommand(BaseCommand):
    """Continue execution until reaching another expression."""

    def __init__(self, context):
        super(NextCommand, self).__init__(context, 'next', gdb.COMMAND_RUNNING)

    def invoke(self, arg, from_tty):
        if arg:
            print('This command takes no argument')
        else:
            go_next(self.context)


class OutCommand(BaseCommand):
    """Continue execution until the end of the evaluation of the current
sub-expression.
    """

    def __init__(self, context):
        super(OutCommand, self).__init__(context, 'out', gdb.COMMAND_RUNNING)

    def invoke(self, arg, from_tty):
        if arg:
            print('This command takes no argument')
        else:
            go_out(self.context)


class StepInsideCommand(BaseCommand):
    """If execution is about to call a property, step inside it. Traverse
dispatch properties in order to land directly in the dispatched property.
    """

    def __init__(self, context):
        super(StepInsideCommand, self).__init__(context, 'si',
                                                gdb.COMMAND_RUNNING)

    def invoke(self, arg, from_tty):
        if arg:
            print('This command takes no argument')
        else:
            go_step_inside(self.context)
