"""
Test the handling of analysis units in the properties DSL.
"""

from __future__ import absolute_import, division, print_function

from langkit.dsl import AnalysisUnitType, ASTNode, Field, LongType, T, abstract
from langkit.expressions import (
    AbstractProperty, ExternalProperty, Property, Self, langkit_property
)
from langkit.parsers import Grammar, Or, Tok

from lexer_example import Token
from utils import build_and_run


class FooNode(ASTNode):
    @langkit_property(public=True)
    def eval_unit(u=AnalysisUnitType):
        return u.root.cast(T.Expression).result


@abstract
class Expression(FooNode):
    result = AbstractProperty(type=LongType, public=True)


class Literal(Expression):
    tok = Field()

    result = ExternalProperty(uses_entity_info=False, uses_envs=False)


class Name(Expression):
    tok = Field()

    designated_unit = ExternalProperty(
        type=AnalysisUnitType, uses_entity_info=False, uses_envs=True
    )
    result = Property(Self.designated_unit.root.cast(Expression).result)


class Plus(Expression):
    left = Field()
    right = Field()

    result = Property(Self.left.result + Self.right.result)


foo_grammar = Grammar('main_rule')
foo_grammar.add_rules(
    main_rule=Or(
        Plus(foo_grammar.atom, '+', foo_grammar.main_rule),
        foo_grammar.atom
    ),
    atom=Or(
        Literal(Tok(Token.Number, keep=True)),
        Name(Tok(Token.Identifier, keep=True)),
    ),
)
build_and_run(foo_grammar, 'main.py')
print('Done')
