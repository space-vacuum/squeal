{-|
Module: Squeal.PostgreSQL.Expression.Null
Description: Null
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Null values and null handling functions
-}

{-# LANGUAGE
    DataKinds
  , OverloadedStrings
  , RankNTypes
  , TypeOperators
#-}

module Squeal.PostgreSQL.Expression.Null
  ( -- * Null
    null_
  , notNull
  , unsafeNotNull
  , monoNotNull
  , coalesce
  , fromNull
  , isNull
  , isNotNull
  , matchNull
  , nullIf
  ) where

import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.Expression.Logic
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

-- | analagous to `Nothing`
--
-- >>> printSQL null_
-- NULL
null_ :: Expr ('Null ty)
null_ = UnsafeExpression "NULL"

-- | analagous to `Just`
--
-- >>> printSQL $ notNull true
-- TRUE
notNull :: 'NotNull ty --> 'Null ty
notNull = UnsafeExpression . renderSQL

-- | Analagous to `Data.Maybe.fromJust` inverse to `notNull`,
-- useful when you know an `Expression` is `NotNull`,
-- because, for instance, you've filtered out @NULL@
-- values in a column.
unsafeNotNull :: 'Null ty --> 'NotNull ty
unsafeNotNull = UnsafeExpression . renderSQL

-- | Some expressions are null polymorphic which may raise
-- inference issues. Use `monoNotNull` to fix their
-- nullity as `NotNull`.
monoNotNull
  :: (forall null. Expression grp lat with db params from (null ty))
  -> Expression grp lat with db params from ('NotNull ty)
monoNotNull = id

-- | return the leftmost value which is not NULL
--
-- >>> printSQL $ coalesce [null_, true] false
-- COALESCE(NULL, TRUE, FALSE)
coalesce :: FunctionVar ('Null ty) (null ty) (null ty)
coalesce nullxs notNullx = UnsafeExpression $
  "COALESCE" <> parenthesized (commaSeparated
    ((renderSQL <$> nullxs) <> [renderSQL notNullx]))

-- | analagous to `Data.Maybe.fromMaybe` using @COALESCE@
--
-- >>> printSQL $ fromNull true null_
-- COALESCE(NULL, TRUE)
fromNull
  :: Expression grp lat with db params from ('NotNull ty)
  -- ^ what to convert @NULL@ to
  -> Expression grp lat with db params from ('Null ty)
  -> Expression grp lat with db params from ('NotNull ty)
fromNull notNullx nullx = coalesce [nullx] notNullx

-- | >>> printSQL $ null_ & isNull
-- NULL IS NULL
isNull :: 'Null ty --> null 'PGbool
isNull x = UnsafeExpression $ renderSQL x <+> "IS NULL"

-- | >>> printSQL $ null_ & isNotNull
-- NULL IS NOT NULL
isNotNull :: 'Null ty --> null 'PGbool
isNotNull x = UnsafeExpression $ renderSQL x <+> "IS NOT NULL"

-- | analagous to `maybe` using @IS NULL@
--
-- >>> printSQL $ matchNull true not_ null_
-- CASE WHEN NULL IS NULL THEN TRUE ELSE (NOT NULL) END
matchNull
  :: Expression grp lat with db params from (nullty)
  -- ^ what to convert @NULL@ to
  -> ( Expression grp lat with db params from ('NotNull ty)
       -> Expression grp lat with db params from (nullty) )
  -- ^ function to perform when @NULL@ is absent
  -> Expression grp lat with db params from ('Null ty)
  -> Expression grp lat with db params from (nullty)
matchNull y f x = ifThenElse (isNull x) y
  (f (UnsafeExpression (renderSQL x)))

{-| right inverse to `fromNull`, if its arguments are equal then
`nullIf` gives @NULL@.

>>> :set -XTypeApplications -XDataKinds
>>> let expr = nullIf (false *: param @1) :: Expression grp lat with db '[ 'NotNull 'PGbool] from ('Null 'PGbool)
>>> printSQL expr
NULLIF(FALSE, ($1 :: bool))
-}
nullIf :: '[ 'NotNull ty, 'NotNull ty] ---> 'Null ty
nullIf = unsafeFunctionN "NULLIF"
