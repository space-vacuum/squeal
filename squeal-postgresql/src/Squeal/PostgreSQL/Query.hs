{-|
Module: Squeal.PostgreSQL.Query
Description: Squeal queries
Copyright: (c) Eitan Chatav, 2017
Maintainer: eitan@morphism.tech
Stability: experimental

Squeal queries.
-}

{-# LANGUAGE
    DeriveGeneric
  , FlexibleContexts
  , FlexibleInstances
  , GADTs
  , GeneralizedNewtypeDeriving
  , LambdaCase
  , MultiParamTypeClasses
  , OverloadedStrings
  , StandaloneDeriving
  , TypeFamilies
  , TypeInType
  , TypeOperators
  , UndecidableInstances
#-}

module Squeal.PostgreSQL.Query
  ( -- * Queries
    Query (UnsafeQuery, renderQuery)
  , Query'
  , QueryFrom (..)
  , queryFrom
  , union
  , unionAll
  , intersect
  , intersectAll
  , except
  , exceptAll
    -- * Select
  , select
  , selectDistinct
  , selectStar
  , selectDistinctStar
  , selectDotStar
  , selectDistinctDotStar
  , values
  , values_
    -- * Table Expressions
  , TableExpression (..)
  , renderTableExpression
  , from
  , where_
  , groupBy
  , having
  , orderBy
  , limit
  , offset
    -- * From
  , FromClause (..)
  , table
  , subquery
  , view
  , crossJoin
  , innerJoin
  , leftOuterJoin
  , rightOuterJoin
  , fullOuterJoin
    -- * Grouping
  , By (By1, By2)
  , renderBy
  , GroupByClause (NoGroups, Group)
  , renderGroupByClause
  , HavingClause (NoHaving, Having)
  , renderHavingClause
    -- * Sorting
  , SortExpression (..)
  , renderSortExpression
  ) where

import Control.DeepSeq
import Data.ByteString (ByteString)
import Data.Kind
import Data.Monoid hiding (All)
import Data.Profunctor
import Data.String
import Data.Word
import Generics.SOP hiding (from)
import GHC.TypeLits

import qualified GHC.Generics as GHC

import Squeal.PostgreSQL.Binary
import Squeal.PostgreSQL.Expression
import Squeal.PostgreSQL.Render
import Squeal.PostgreSQL.Schema

{- |
The process of retrieving or the command to retrieve data from a database
is called a `Query`. The `select`, `selectStar`, `selectDotStar`,
`selectDistinct`, `selectDistinctStar` and `selectDistinctDotStar` commands
are used to specify queries.

simple query:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query = selectStar (from (table #tab))
in printSQL query
:}
SELECT * FROM "tab" AS "tab"

restricted query:

>>> :{
let
  query :: Query
    '[ "tab" ::: 'Table ('[] :=>
       '[ "col1" ::: 'NoDef :=> 'NotNull 'PGint4
        , "col2" ::: 'NoDef :=> 'NotNull 'PGint4 ])]
    '[]
    '[ "sum" ::: 'NotNull 'PGint4
     , "col1" ::: 'NotNull 'PGint4 ]
  query =
    select
      ((#col1 + #col2) `as` #sum :* #col1)
      ( from (table #tab)
        & where_ (#col1 .> #col2)
        & where_ (#col2 .> 0) )
in printSQL query
:}
SELECT ("col1" + "col2") AS "sum", "col1" AS "col1" FROM "tab" AS "tab" WHERE (("col1" > "col2") AND ("col2" > 0))

subquery:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query =
    selectStar
      (from (subquery (selectStar (from (table #tab)) `as` #sub)))
in printSQL query
:}
SELECT * FROM (SELECT * FROM "tab" AS "tab") AS "sub"

limits and offsets:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query = selectStar
    (from (table #tab) & limit 100 & offset 2 & limit 50 & offset 2)
in printSQL query
:}
SELECT * FROM "tab" AS "tab" LIMIT 50 OFFSET 4

parameterized query:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'NotNull 'PGfloat8])]
    '[ 'NotNull 'PGfloat8]
    '["col" ::: 'NotNull 'PGfloat8]
  query = selectStar
    (from (table #tab) & where_ (#col .> param @1))
in printSQL query
:}
SELECT * FROM "tab" AS "tab" WHERE ("col" > ($1 :: float8))

aggregation query:

>>> :{
let
  query :: Query
    '[ "tab" ::: 'Table ('[] :=>
       '[ "col1" ::: 'NoDef :=> 'NotNull 'PGint4
        , "col2" ::: 'NoDef :=> 'NotNull 'PGint4 ])]
    '[]
    '[ "sum" ::: 'NotNull 'PGint4
     , "col1" ::: 'NotNull 'PGint4 ]
  query =
    select (sum_ #col2 `as` #sum :* #col1)
    ( from (table (#tab `as` #table1))
      & groupBy #col1
      & having (#col1 + sum_ #col2 .> 1) )
in printSQL query
:}
SELECT sum("col2") AS "sum", "col1" AS "col1" FROM "tab" AS "table1" GROUP BY "col1" HAVING (("col1" + sum("col2")) > 1)

sorted query:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query = selectStar
    (from (table #tab) & orderBy [#col & AscNullsFirst])
in printSQL query
:}
SELECT * FROM "tab" AS "tab" ORDER BY "col" ASC NULLS FIRST

joins:

>>> :set -XFlexibleContexts
>>> :{
let
  query :: Query
    '[ "orders" ::: 'Table (
         '["pk_orders" ::: PrimaryKey '["id"]
          ,"fk_customers" ::: ForeignKey '["customer_id"] "customers" '["id"]
          ,"fk_shippers" ::: ForeignKey '["shipper_id"] "shippers" '["id"]] :=>
         '[ "id"    ::: 'NoDef :=> 'NotNull 'PGint4
          , "price"   ::: 'NoDef :=> 'NotNull 'PGfloat4
          , "customer_id" ::: 'NoDef :=> 'NotNull 'PGint4
          , "shipper_id"  ::: 'NoDef :=> 'NotNull 'PGint4
          ])
     , "customers" ::: 'Table (
         '["pk_customers" ::: PrimaryKey '["id"]] :=>
         '[ "id" ::: 'NoDef :=> 'NotNull 'PGint4
          , "name" ::: 'NoDef :=> 'NotNull 'PGtext
          ])
     , "shippers" ::: 'Table (
         '["pk_shippers" ::: PrimaryKey '["id"]] :=>
         '[ "id" ::: 'NoDef :=> 'NotNull 'PGint4
          , "name" ::: 'NoDef :=> 'NotNull 'PGtext
          ])
     ]
    '[]
    '[ "order_price" ::: 'NotNull 'PGfloat4
     , "customer_name" ::: 'NotNull 'PGtext
     , "shipper_name" ::: 'NotNull 'PGtext
     ]
  query = select
    ( #o ! #price `as` #order_price :*
      #c ! #name `as` #customer_name :*
      #s ! #name `as` #shipper_name )
    ( from (table (#orders `as` #o)
      & innerJoin (table (#customers `as` #c))
        (#o ! #customer_id .== #c ! #id)
      & innerJoin (table (#shippers `as` #s))
        (#o ! #shipper_id .== #s ! #id)) )
in printSQL query
:}
SELECT "o"."price" AS "order_price", "c"."name" AS "customer_name", "s"."name" AS "shipper_name" FROM "orders" AS "o" INNER JOIN "customers" AS "c" ON ("o"."customer_id" = "c"."id") INNER JOIN "shippers" AS "s" ON ("o"."shipper_id" = "s"."id")

self-join:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query = selectDotStar #t1
    (from (table (#tab `as` #t1) & crossJoin (table (#tab `as` #t2))))
in printSQL query
:}
SELECT "t1".* FROM "tab" AS "t1" CROSS JOIN "tab" AS "t2"

set operations:

>>> :{
let
  query :: Query
    '["tab" ::: 'Table ('[] :=> '["col" ::: 'NoDef :=> 'Null 'PGint4])]
    '[]
    '["col" ::: 'Null 'PGint4]
  query =
    selectStar (from (table #tab))
    `unionAll`
    selectStar (from (table #tab))
in printSQL query
:}
(SELECT * FROM "tab" AS "tab") UNION ALL (SELECT * FROM "tab" AS "tab")
-}
newtype Query
  (schema :: SchemaType)
  (params :: [NullityType])
  (columns :: RelationType)
    = UnsafeQuery { renderQuery :: ByteString }
    deriving (GHC.Generic,Show,Eq,Ord,NFData)
instance RenderSQL (Query schema params columns) where renderSQL = renderQuery

data QueryFrom
  (schema :: SchemaType)
  (x :: Type)
  (y :: Type)
  where
    QueryFrom
      :: (x -> NP (K (Maybe ByteString)) params)
      -> Query schema params result
      -> (NP (K (Maybe ByteString)) result -> y)
      -> QueryFrom schema x y
instance Profunctor (QueryFrom schema) where
  dimap f g (QueryFrom params q result) = QueryFrom (params.f) q (g.result)

queryFrom
  :: (ToParams x (ParamsFrom x), FromRow (ResultFrom y) y)
  => Query schema (ParamsFrom x) (ResultFrom y)
  -> QueryFrom schema x y
queryFrom q = QueryFrom toParams q fromRow

type family Query' schema x y where
  Query' schema x y = Query schema (ParamsFrom x) (ResultFrom y)

-- | The results of two queries can be combined using the set operation
-- `union`. Duplicate rows are eliminated.
union
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `union` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "UNION"
  <+> parenthesized (renderQuery q2)

-- | The results of two queries can be combined using the set operation
-- `unionAll`, the disjoint union. Duplicate rows are retained.
unionAll
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `unionAll` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "UNION" <+> "ALL"
  <+> parenthesized (renderQuery q2)

-- | The results of two queries can be combined using the set operation
-- `intersect`, the intersection. Duplicate rows are eliminated.
intersect
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `intersect` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "INTERSECT"
  <+> parenthesized (renderQuery q2)

-- | The results of two queries can be combined using the set operation
-- `intersectAll`, the intersection. Duplicate rows are retained.
intersectAll
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `intersectAll` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "INTERSECT" <+> "ALL"
  <+> parenthesized (renderQuery q2)

-- | The results of two queries can be combined using the set operation
-- `except`, the set difference. Duplicate rows are eliminated.
except
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `except` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "EXCEPT"
  <+> parenthesized (renderQuery q2)

-- | The results of two queries can be combined using the set operation
-- `exceptAll`, the set difference. Duplicate rows are retained.
exceptAll
  :: Query schema params columns
  -> Query schema params columns
  -> Query schema params columns
q1 `exceptAll` q2 = UnsafeQuery $
  parenthesized (renderQuery q1)
  <+> "EXCEPT" <+> "ALL"
  <+> parenthesized (renderQuery q2)

{-----------------------------------------
SELECT queries
-----------------------------------------}

-- | the `TableExpression` in the `select` command constructs an intermediate
-- virtual table by possibly combining tables, views, eliminating rows,
-- grouping, etc. This table is finally passed on to processing by
-- the select list. The select list determines which columns of
-- the intermediate table are actually output.
select
  :: SListI columns
  => NP (Aliased (Expression schema relations grouping params)) (column ': columns)
  -- ^ select list
  -> TableExpression schema params relations grouping
  -- ^ intermediate virtual table
  -> Query schema params (column ': columns)
select list rels = UnsafeQuery $
  "SELECT"
  <+> renderCommaSeparated (renderAliasedAs renderExpression) list
  <+> renderTableExpression rels

-- | After the select list has been processed, the result table can
-- be subject to the elimination of duplicate rows using `selectDistinct`.
selectDistinct
  :: SListI columns
  => NP (Aliased (Expression schema relations 'Ungrouped params)) (column ': columns)
  -- ^ select list
  -> TableExpression schema params relations 'Ungrouped
  -- ^ intermediate virtual table
  -> Query schema params (column ': columns)
selectDistinct list rels = UnsafeQuery $
  "SELECT DISTINCT"
  <+> renderCommaSeparated (renderAliasedAs renderExpression) list
  <+> renderTableExpression rels

-- | The simplest kind of query is `selectStar` which emits all columns
-- that the table expression produces.
selectStar
  :: HasUnique relation relations columns
  => TableExpression schema params relations 'Ungrouped
  -- ^ intermediate virtual table
  -> Query schema params columns
selectStar rels = UnsafeQuery $ "SELECT" <+> "*" <+> renderTableExpression rels

-- | A `selectDistinctStar` emits all columns that the table expression
-- produces and eliminates duplicate rows.
selectDistinctStar
  :: HasUnique relation relations columns
  => TableExpression schema params relations 'Ungrouped
  -- ^ intermediate virtual table
  -> Query schema params columns
selectDistinctStar rels = UnsafeQuery $
  "SELECT DISTINCT" <+> "*" <+> renderTableExpression rels

-- | When working with multiple tables, it can also be useful to ask
-- for all the columns of a particular table, using `selectDotStar`.
selectDotStar
  :: Has relation relations columns
  => Alias relation
  -- ^ particular virtual subtable
  -> TableExpression schema params relations 'Ungrouped
  -- ^ intermediate virtual table
  -> Query schema params columns
selectDotStar rel relations = UnsafeQuery $
  "SELECT" <+> renderAlias rel <> ".*" <+> renderTableExpression relations

-- | A `selectDistinctDotStar` asks for all the columns of a particular table,
-- and eliminates duplicate rows.
selectDistinctDotStar
  :: Has relation relations columns
  => Alias relation
  -- ^ particular virtual table
  -> TableExpression schema params relations 'Ungrouped
  -- ^ intermediate virtual table
  -> Query schema params columns
selectDistinctDotStar rel relations = UnsafeQuery $
  "SELECT DISTINCT" <+> renderAlias rel <> ".*"
  <+> renderTableExpression relations

-- | `values` computes a row value or set of row values
-- specified by value expressions. It is most commonly used
-- to generate a “constant table” within a larger command,
-- but it can be used on its own.
--
-- >>> type Row = '["a" ::: 'NotNull 'PGint4, "b" ::: 'NotNull 'PGtext]
-- >>> let query = values (1 `as` #a :* "one" `as` #b) [] :: Query '[] '[] Row
-- >>> printSQL query
-- SELECT * FROM (VALUES (1, E'one')) AS t ("a", "b")
values
  :: SListI cols
  => NP (Aliased (Expression schema '[] 'Ungrouped params)) cols
  -> [NP (Aliased (Expression schema '[] 'Ungrouped params)) cols]
  -- ^ When more than one row is specified, all the rows must
  -- must have the same number of elements
  -> Query schema params cols
values rw rws = UnsafeQuery $ "SELECT * FROM"
  <+> parenthesized (
    "VALUES"
    <+> commaSeparated
        ( parenthesized
        . renderCommaSeparated renderValuePart <$> rw:rws )
    ) <+> "AS t"
  <+> parenthesized (renderCommaSeparated renderAliasPart rw)
  where
    renderAliasPart, renderValuePart
      :: Aliased (Expression schema '[] 'Ungrouped params) ty -> ByteString
    renderAliasPart (_ `As` name) = renderAlias name
    renderValuePart (value `As` _) = renderExpression value

-- | `values_` computes a row value or set of row values
-- specified by value expressions.
values_
  :: SListI cols
  => NP (Aliased (Expression schema '[] 'Ungrouped params)) cols
  -- ^ one row of values
  -> Query schema params cols
values_ rw = values rw []

{-----------------------------------------
Table Expressions
-----------------------------------------}

-- | A `TableExpression` computes a table. The table expression contains
-- a `fromClause` that is optionally followed by a `whereClause`,
-- `groupByClause`, `havingClause`, `orderByClause`, `limitClause`
-- and `offsetClause`s. Trivial table expressions simply refer
-- to a table on disk, a so-called base table, but more complex expressions
-- can be used to modify or combine base tables in various ways.
data TableExpression
  (schema :: SchemaType)
  (params :: [NullityType])
  (relations :: RelationsType)
  (grouping :: Grouping)
    = TableExpression
    { fromClause :: FromClause schema params relations
    -- ^ A table reference that can be a table name, or a derived table such
    -- as a subquery, a @JOIN@ construct, or complex combinations of these.
    , whereClause :: [Condition schema relations 'Ungrouped params]
    -- ^ optional search coditions, combined with `.&&`. After the processing
    -- of the `fromClause` is done, each row of the derived virtual table
    -- is checked against the search condition. If the result of the
    -- condition is true, the row is kept in the output table,
    -- otherwise it is discarded. The search condition typically references
    -- at least one column of the table generated in the `fromClause`;
    -- this is not required, but otherwise the WHERE clause will
    -- be fairly useless.
    , groupByClause :: GroupByClause relations grouping
    -- ^ The `groupByClause` is used to group together those rows in a table
    -- that have the same values in all the columns listed. The order in which
    -- the columns are listed does not matter. The effect is to combine each
    -- set of rows having common values into one group row that represents all
    -- rows in the group. This is done to eliminate redundancy in the output
    -- and/or compute aggregates that apply to these groups.
    , havingClause :: HavingClause schema relations grouping params
    -- ^ If a table has been grouped using `groupBy`, but only certain groups
    -- are of interest, the `havingClause` can be used, much like a
    -- `whereClause`, to eliminate groups from the result. Expressions in the
    -- `havingClause` can refer both to grouped expressions and to ungrouped
    -- expressions (which necessarily involve an aggregate function).
    , orderByClause :: [SortExpression schema relations grouping params]
    -- ^ The `orderByClause` is for optional sorting. When more than one
    -- `SortExpression` is specified, the later (right) values are used to sort
    -- rows that are equal according to the earlier (left) values.
    , limitClause :: [Word64]
    -- ^ The `limitClause` is combined with `min` to give a limit count
    -- if nonempty. If a limit count is given, no more than that many rows
    -- will be returned (but possibly fewer, if the query itself yields
    -- fewer rows).
    , offsetClause :: [Word64]
    -- ^ The `offsetClause` is combined with `+` to give an offset count
    -- if nonempty. The offset count says to skip that many rows before
    -- beginning to return rows. The rows are skipped before the limit count
    -- is applied.
    }

-- | Render a `TableExpression`
renderTableExpression
  :: TableExpression schema params relations grouping
  -> ByteString
renderTableExpression
  (TableExpression frm' whs' grps' hvs' srts' lims' offs') = mconcat
    [ "FROM ", renderFromClause frm'
    , renderWheres whs'
    , renderGroupByClause grps'
    , renderHavingClause hvs'
    , renderOrderByClause srts'
    , renderLimits lims'
    , renderOffsets offs'
    ]
    where
      renderWheres = \case
        [] -> ""
        wh:[] -> " WHERE" <+> renderExpression wh
        wh:whs -> " WHERE" <+> renderExpression (foldr (.&&) wh whs)
      renderOrderByClause = \case
        [] -> ""
        srts -> " ORDER BY"
          <+> commaSeparated (renderSortExpression <$> srts)
      renderLimits = \case
        [] -> ""
        lims -> " LIMIT" <+> fromString (show (minimum lims))
      renderOffsets = \case
        [] -> ""
        offs -> " OFFSET" <+> fromString (show (sum offs))

-- | A `from` generates a `TableExpression` from a table reference that can be
-- a table name, or a derived table such as a subquery, a JOIN construct,
-- or complex combinations of these. A `from` may be transformed by `where_`,
-- `group`, `having`, `orderBy`, `limit` and `offset`, using the `&` operator
-- to match the left-to-right sequencing of their placement in SQL.
from
  :: FromClause schema params relations -- ^ table reference
  -> TableExpression schema params relations 'Ungrouped
from rels = TableExpression rels [] NoGroups NoHaving [] [] []

-- | A `where_` is an endomorphism of `TableExpression`s which adds a
-- search condition to the `whereClause`.
where_
  :: Condition schema relations 'Ungrouped params -- ^ filtering condition
  -> TableExpression schema params relations grouping
  -> TableExpression schema params relations grouping
where_ wh rels = rels {whereClause = wh : whereClause rels}

-- | A `groupBy` is a transformation of `TableExpression`s which switches
-- its `Grouping` from `Ungrouped` to `Grouped`. Use @group Nil@ to perform
-- a "grand total" aggregation query.
groupBy
  :: SListI bys
  => NP (By relations) bys -- ^ grouped columns
  -> TableExpression schema params relations 'Ungrouped
  -> TableExpression schema params relations ('Grouped bys)
groupBy bys rels = TableExpression
  { fromClause = fromClause rels
  , whereClause = whereClause rels
  , groupByClause = Group bys
  , havingClause = Having []
  , orderByClause = []
  , limitClause = limitClause rels
  , offsetClause = offsetClause rels
  }

-- | A `having` is an endomorphism of `TableExpression`s which adds a
-- search condition to the `havingClause`.
having
  :: Condition schema relations ('Grouped bys) params -- ^ having condition
  -> TableExpression schema params relations ('Grouped bys)
  -> TableExpression schema params relations ('Grouped bys)
having hv rels = rels
  { havingClause = case havingClause rels of Having hvs -> Having (hv:hvs) }

-- | An `orderBy` is an endomorphism of `TableExpression`s which appends an
-- ordering to the right of the `orderByClause`.
orderBy
  :: [SortExpression schema relations grouping params] -- ^ sort expressions
  -> TableExpression schema params relations grouping
  -> TableExpression schema params relations grouping
orderBy srts rels = rels {orderByClause = orderByClause rels ++ srts}

-- | A `limit` is an endomorphism of `TableExpression`s which adds to the
-- `limitClause`.
limit
  :: Word64 -- ^ limit parameter
  -> TableExpression schema params relations grouping
  -> TableExpression schema params relations grouping
limit lim rels = rels {limitClause = lim : limitClause rels}

-- | An `offset` is an endomorphism of `TableExpression`s which adds to the
-- `offsetClause`.
offset
  :: Word64 -- ^ offset parameter
  -> TableExpression schema params relations grouping
  -> TableExpression schema params relations grouping
offset off rels = rels {offsetClause = off : offsetClause rels}

{-----------------------------------------
FROM clauses
-----------------------------------------}

{- |
A `FromClause` can be a table name, or a derived table such
as a subquery, a @JOIN@ construct, or complex combinations of these.
-}
newtype FromClause schema params relations
  = UnsafeFromClause { renderFromClause :: ByteString }
  deriving (GHC.Generic,Show,Eq,Ord,NFData)

-- | A real `table` is a table from the schema.
table
  :: Has tab schema ('Table table)
  => Aliased Alias (alias ::: tab)
  -> FromClause schema params '[alias ::: TableToRelation table]
table (tab `As` alias) = UnsafeFromClause $
  renderAlias tab <+> "AS" <+> renderAlias alias

-- | `subquery` derives a table from a `Query`.
subquery
  :: Aliased (Query schema params) rel
  -> FromClause schema params '[rel]
subquery = UnsafeFromClause . renderAliasedAs (parenthesized . renderQuery)

-- | `view` derives a table from a `View`.
view
  :: Has view schema ('View rel)
  => Aliased Alias (alias ::: view)
  -> FromClause schema params '[alias ::: rel]
view (vw `As` alias) = UnsafeFromClause $
  renderAlias vw <+> "AS" <+> renderAlias alias

{- | @left & crossJoin right@. For every possible combination of rows from
    @left@ and @right@ (i.e., a Cartesian product), the joined table will contain
    a row consisting of all columns in @left@ followed by all columns in @right@.
    If the tables have @n@ and @m@ rows respectively, the joined table will
    have @n * m@ rows.
-}
crossJoin
  :: FromClause schema params right
  -- ^ right
  -> FromClause schema params left
  -- ^ left
  -> FromClause schema params (Join left right)
crossJoin right left = UnsafeFromClause $
  renderFromClause left <+> "CROSS JOIN" <+> renderFromClause right

{- | @left & innerJoin right on@. The joined table is filtered by
the @on@ condition.
-}
innerJoin
  :: FromClause schema params right
  -- ^ right
  -> Condition schema (Join left right) 'Ungrouped params
  -- ^ @on@ condition
  -> FromClause schema params left
  -- ^ left
  -> FromClause schema params (Join left right)
innerJoin right on left = UnsafeFromClause $
  renderFromClause left <+> "INNER JOIN" <+> renderFromClause right
  <+> "ON" <+> renderExpression on

{- | @left & leftOuterJoin right on@. First, an inner join is performed.
    Then, for each row in @left@ that does not satisfy the @on@ condition with
    any row in @right@, a joined row is added with null values in columns of @right@.
    Thus, the joined table always has at least one row for each row in @left@.
-}
leftOuterJoin
  :: FromClause schema params right
  -- ^ right
  -> Condition schema (Join left right) 'Ungrouped params
  -- ^ @on@ condition
  -> FromClause schema params left
  -- ^ left
  -> FromClause schema params (Join left (NullifyRelations right))
leftOuterJoin right on left = UnsafeFromClause $
  renderFromClause left <+> "LEFT OUTER JOIN" <+> renderFromClause right
  <+> "ON" <+> renderExpression on

{- | @left & rightOuterJoin right on@. First, an inner join is performed.
    Then, for each row in @right@ that does not satisfy the @on@ condition with
    any row in @left@, a joined row is added with null values in columns of @left@.
    This is the converse of a left join: the result table will always
    have a row for each row in @right@.
-}
rightOuterJoin
  :: FromClause schema params right
  -- ^ right
  -> Condition schema (Join left right) 'Ungrouped params
  -- ^ @on@ condition
  -> FromClause schema params left
  -- ^ left
  -> FromClause schema params (Join (NullifyRelations left) right)
rightOuterJoin right on left = UnsafeFromClause $
  renderFromClause left <+> "RIGHT OUTER JOIN" <+> renderFromClause right
  <+> "ON" <+> renderExpression on

{- | @left & fullOuterJoin right on@. First, an inner join is performed.
    Then, for each row in @left@ that does not satisfy the @on@ condition with
    any row in @right@, a joined row is added with null values in columns of @right@.
    Also, for each row of @right@ that does not satisfy the join condition
    with any row in @left@, a joined row with null values in the columns of @left@
    is added.
-}
fullOuterJoin
  :: FromClause schema params right
  -- ^ right
  -> Condition schema (Join left right) 'Ungrouped params
  -- ^ @on@ condition
  -> FromClause schema params left
  -- ^ left
  -> FromClause schema params
      (Join (NullifyRelations left) (NullifyRelations right))
fullOuterJoin right on left = UnsafeFromClause $
  renderFromClause left <+> "FULL OUTER JOIN" <+> renderFromClause right
  <+> "ON" <+> renderExpression on

{-----------------------------------------
Grouping
-----------------------------------------}

-- | `By`s are used in `group` to reference a list of columns which are then
-- used to group together those rows in a table that have the same values
-- in all the columns listed. @By \#col@ will reference an unambiguous
-- column @col@; otherwise @By2 (\#tab \! \#col)@ will reference a table
-- qualified column @tab.col@.
data By
    (relations :: RelationsType)
    (by :: (Symbol,Symbol)) where
    By1
      :: (HasUnique relation relations columns, Has column columns ty)
      => Alias column
      -> By relations '(relation, column)
    By2
      :: (Has relation relations columns, Has column columns ty)
      => Alias relation
      -> Alias column
      -> By relations '(relation, column)
deriving instance Show (By relations by)
deriving instance Eq (By relations by)
deriving instance Ord (By relations by)

instance (HasUnique rel rels cols, Has col cols ty, by ~ '(rel, col))
  => IsLabel col (By rels by) where fromLabel = By1 fromLabel
instance (HasUnique rel rels cols, Has col cols ty, bys ~ '[ '(rel, col)])
  => IsLabel col (NP (By rels) bys) where fromLabel = By1 fromLabel :* Nil
instance (Has rel rels cols, Has col cols ty, by ~ '(rel, col))
  => IsQualified rel col (By rels by) where (!) = By2
instance (Has rel rels cols, Has col cols ty, bys ~ '[ '(rel, col)])
  => IsQualified rel col (NP (By rels) bys) where
    rel ! col = By2 rel col :* Nil

-- | Renders a `By`.
renderBy :: By relations by -> ByteString
renderBy = \case
  By1 column -> renderAlias column
  By2 rel column -> renderAlias rel <> "." <> renderAlias column

-- | A `GroupByClause` indicates the `Grouping` of a `TableExpression`.
-- A `NoGroups` indicates `Ungrouped` while a `Group` indicates `Grouped`.
-- @NoGroups@ is distinguised from @Group Nil@ since no aggregation can be
-- done on @NoGroups@ while all output `Expression`s must be aggregated
-- in @Group Nil@. In general, all output `Expression`s in the
-- complement of @bys@ must be aggregated in @Group bys@.
data GroupByClause relations grouping where
  NoGroups :: GroupByClause relations 'Ungrouped
  Group
    :: SListI bys
    => NP (By relations) bys
    -> GroupByClause relations ('Grouped bys)

-- | Renders a `GroupByClause`.
renderGroupByClause :: GroupByClause relations grouping -> ByteString
renderGroupByClause = \case
  NoGroups -> ""
  Group Nil -> ""
  Group bys -> " GROUP BY" <+> renderCommaSeparated renderBy bys

-- | A `HavingClause` is used to eliminate groups that are not of interest.
-- An `Ungrouped` `TableExpression` may only use `NoHaving` while a `Grouped`
-- `TableExpression` must use `Having` whose conditions are combined with
-- `.&&`.
data HavingClause schema relations grouping params where
  NoHaving :: HavingClause schema relations 'Ungrouped params
  Having
    :: [Condition schema relations ('Grouped bys) params]
    -> HavingClause schema relations ('Grouped bys) params
deriving instance Show (HavingClause schema relations grouping params)
deriving instance Eq (HavingClause schema relations grouping params)
deriving instance Ord (HavingClause schema relations grouping params)

-- | Render a `HavingClause`.
renderHavingClause :: HavingClause schema relations grouping params -> ByteString
renderHavingClause = \case
  NoHaving -> ""
  Having [] -> ""
  Having conditions ->
    " HAVING" <+> commaSeparated (renderExpression <$> conditions)

{-----------------------------------------
Sorting
-----------------------------------------}

-- | `SortExpression`s are used by `sortBy` to optionally sort the results
-- of a `Query`. `Asc` or `Desc` set the sort direction of a `NotNull` result
-- column to ascending or descending. Ascending order puts smaller values
-- first, where "smaller" is defined in terms of the `.<` operator. Similarly,
-- descending order is determined with the `.>` operator. `AscNullsFirst`,
-- `AscNullsLast`, `DescNullsFirst` and `DescNullsLast` options are used to
-- determine whether nulls appear before or after non-null values in the sort
-- ordering of a `Null` result column.
data SortExpression schema relations grouping params where
    Asc
      :: Expression schema relations grouping params ('NotNull ty)
      -> SortExpression schema relations grouping params
    Desc
      :: Expression schema relations grouping params ('NotNull ty)
      -> SortExpression schema relations grouping params
    AscNullsFirst
      :: Expression schema relations grouping params  ('Null ty)
      -> SortExpression schema relations grouping params
    AscNullsLast
      :: Expression schema relations grouping params  ('Null ty)
      -> SortExpression schema relations grouping params
    DescNullsFirst
      :: Expression schema relations grouping params  ('Null ty)
      -> SortExpression schema relations grouping params
    DescNullsLast
      :: Expression schema relations grouping params  ('Null ty)
      -> SortExpression schema relations grouping params
deriving instance Show (SortExpression schema relations grouping params)

-- | Render a `SortExpression`.
renderSortExpression :: SortExpression schema relations grouping params -> ByteString
renderSortExpression = \case
  Asc expression -> renderExpression expression <+> "ASC"
  Desc expression -> renderExpression expression <+> "DESC"
  AscNullsFirst expression -> renderExpression expression
    <+> "ASC NULLS FIRST"
  DescNullsFirst expression -> renderExpression expression
    <+> "DESC NULLS FIRST"
  AscNullsLast expression -> renderExpression expression <+> "ASC NULLS LAST"
  DescNullsLast expression -> renderExpression expression <+> "DESC NULLS LAST"
