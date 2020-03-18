{-|
Module: Squeal.PostgreSQL.Expression.Math
Description: Math expressions
Copyright: (c) Eitan Chatav, 2019
Maintainer: eitan@morphism.tech
Stability: experimental

Mathematical functions
-}

{-# LANGUAGE
    DataKinds
  , OverloadedStrings
  , TypeOperators
#-}

module Squeal.PostgreSQL.Expression.Math
  ( -- * Math Function
    atan2_
  , quot_
  , rem_
  , trunc
  , round_
  , ceiling_
  ) where

import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.List
import Squeal.PostgreSQL.Schema

-- $setup
-- >>> import Squeal.PostgreSQL

-- | >>> :{
-- let
--   expression :: Expr (null 'PGfloat4)
--   expression = atan2_ (pi *: 2)
-- in printSQL expression
-- :}
-- atan2(pi(), (2.0 :: float4))
atan2_ :: float `In` PGFloating => '[ null float, null float] ---> null float
atan2_ = unsafeFunctionN "atan2"


-- | integer division, truncates the result
--
-- >>> :{
-- let
--   expression :: Expression grp lat with db params from (null 'PGint2)
--   expression = 5 `quot_` 2
-- in printSQL expression
-- :}
-- ((5 :: int2) / (2 :: int2))
quot_
  :: int `In` PGIntegral
  => Operator (null int) (null int) (null int)
quot_ = unsafeBinaryOp "/"

-- | remainder upon integer division
--
-- >>> :{
-- let
--   expression :: Expression grp lat with db params from (null 'PGint2)
--   expression = 5 `rem_` 2
-- in printSQL expression
-- :}
-- ((5 :: int2) % (2 :: int2))
rem_
  :: int `In` PGIntegral
  => Operator (null int) (null int) (null int)
rem_ = unsafeBinaryOp "%"

-- | >>> :{
-- let
--   expression :: Expression grp lat with db params from (null 'PGfloat4)
--   expression = trunc pi
-- in printSQL expression
-- :}
-- trunc(pi())
trunc :: frac `In` PGFloating => null frac --> null frac
trunc = unsafeFunction "trunc"

-- | >>> :{
-- let
--   expression :: Expression grp lat with db params from (null 'PGfloat4)
--   expression = round_ pi
-- in printSQL expression
-- :}
-- round(pi())
round_ :: frac `In` PGFloating => null frac --> null frac
round_ = unsafeFunction "round"

-- | >>> :{
-- let
--   expression :: Expression grp lat with db params from (null 'PGfloat4)
--   expression = ceiling_ pi
-- in printSQL expression
-- :}
-- ceiling(pi())
ceiling_ :: frac `In` PGFloating => null frac --> null frac
ceiling_ = unsafeFunction "ceiling"
