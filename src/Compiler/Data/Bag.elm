module Compiler.Data.Bag exposing
    ( Bag(..)
    , append
    , empty
    , one
    , toList
    )

-- BAGS


type Bag a
    = Empty
    | One a
    | Two (Bag a) (Bag a)



-- HELPERS


empty : Bag a
empty =
    Empty


one : a -> Bag a
one =
    One


append : Bag a -> Bag a -> Bag a
append left right =
    case ( left, right ) of
        ( other, Empty ) ->
            other

        ( Empty, other ) ->
            other

        _ ->
            Two left right



-- TO LIST


toList : Bag a -> List a
toList bag =
    toListHelp bag []


toListHelp : Bag a -> List a -> List a
toListHelp bag list =
    case bag of
        Empty ->
            list

        One x ->
            x :: list

        Two a b ->
            toListHelp a (toListHelp b list)
