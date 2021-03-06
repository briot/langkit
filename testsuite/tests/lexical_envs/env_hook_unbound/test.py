from __future__ import absolute_import, division, print_function

from langkit.dsl import ASTNode
from langkit.envs import EnvSpec, call_env_hook
from langkit.expressions import Self
from langkit.parsers import Grammar

from utils import emit_and_print_errors


class FooNode(ASTNode):
    pass


class BarNode(FooNode):
    env_spec = EnvSpec(call_env_hook(Self))


grammar = Grammar('main_rule')
grammar.add_rules(
    main_rule=BarNode('example'),
)
emit_and_print_errors(grammar)
print('Done')
