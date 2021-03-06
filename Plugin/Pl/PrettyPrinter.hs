{-# LANGUAGE PatternGuards #-}
module Plugin.Pl.PrettyPrinter (
  prettyDecl,
  prettyExpr,
  prettyTopLevel,
 ) where

import Plugin.Pl.Common

import Data.Char
import Data.List (intercalate)

prettyDecl :: Decl -> String
prettyDecl (Define f e) = f ++ " = " ++ prettyExpr e

prettyDecls :: [Decl] -> String
prettyDecls = intercalate "; " . map prettyDecl

prettyExpr :: Expr -> String
prettyExpr = show . toSExpr

prettyTopLevel :: TopLevel -> String
prettyTopLevel (TLE e) = prettyExpr e
prettyTopLevel (TLD _ d) = prettyDecl d

data SExpr
  = SVar !String
  | SLambda ![Pattern] !SExpr
  | SLet ![Decl] !SExpr
  | SApp !SExpr !SExpr
  | SInfix !String !SExpr !SExpr
  | LeftSection !String !SExpr  -- (x +)
  | RightSection !String !SExpr -- (+ x)
  | List ![SExpr]
  | Tuple ![SExpr]
  | Enum !Expr !(Maybe Expr) !(Maybe Expr)

{-# INLINE toSExprHead #-}
toSExprHead :: String -> [Expr] -> Maybe SExpr
toSExprHead hd tl
  | all (==',') hd, length hd+1 == length tl 
  = Just . Tuple . reverse $ map toSExpr tl
  | otherwise = case (hd,reverse tl) of
      ("enumFrom", [e])              -> Just $ Enum e Nothing   Nothing
      ("enumFromThen", [e,e'])       -> Just $ Enum e (Just e') Nothing
      ("enumFromTo", [e,e'])         -> Just $ Enum e Nothing   (Just e')
      ("enumFromThenTo", [e,e',e'']) -> Just $ Enum e (Just e') (Just e'')
      _                              -> Nothing

toSExpr :: Expr -> SExpr
toSExpr (Var _ v) = SVar v
toSExpr (Lambda v e) = case toSExpr e of
  (SLambda vs e') -> SLambda (v:vs) e'
  e'              -> SLambda [v] e'
toSExpr (Let ds e) = SLet ds $ toSExpr e
toSExpr e | Just (hd,tl) <- getHead e, Just se <- toSExprHead hd tl = se
toSExpr e | (ls, tl) <- getList e, tl == nil
  = List $ map toSExpr ls
toSExpr (App e1 e2) = case e1 of
  App (Var Inf v) e0 
    -> SInfix v (toSExpr e0) (toSExpr e2)
  Var Inf v | v /= "-"
    -> LeftSection v (toSExpr e2)

  Var _ "flip" | Var Inf v <- e2, v == "-" -> toSExpr $ Var Pref "subtract"
    
  App (Var _ "flip") (Var pr v)
    | v == "-"  -> toSExpr $ Var Pref "subtract" `App` e2
    | v == "id" -> RightSection "$" (toSExpr e2)
    | Inf <- pr, any (/= ',') v -> RightSection v (toSExpr e2)
  _ -> SApp (toSExpr e1) (toSExpr e2)

getHead :: Expr -> Maybe (String, [Expr])
getHead (Var _ v) = Just (v, [])
getHead (App e1 e2) = second (e2:) `fmap` getHead e1
getHead _ = Nothing

instance Show SExpr where
  showsPrec _ (SVar v) = (getPrefName v ++)
  showsPrec p (SLambda vs e) = showParen (p > minPrec) $ ('\\':) . 
    foldr (.) id (intersperse (' ':) (map (prettyPrecPattern $ maxPrec+1) vs)) .
    (" -> "++) . showsPrec minPrec e
  showsPrec p (SApp e1 e2) = showParen (p > maxPrec) $
    showsPrec maxPrec e1 . (' ':) . showsPrec (maxPrec+1) e2
  showsPrec _ (LeftSection fx e) = showParen True $ 
    showsPrec (snd (lookupFix fx) + 1) e . (' ':) . (getInfName fx++)
  showsPrec _ (RightSection fx e) = showParen True $ 
    (getInfName fx++) . (' ':) . showsPrec (snd (lookupFix fx) + 1) e
  showsPrec _ (Tuple es) = showParen True $
    (concat `id` intersperse ", " (map show es) ++)
  
  showsPrec _ (List es) 
    | Just cs <- mapM ((=<<) readM . fromSVar) es = shows (cs::String)
    | otherwise = ('[':) . 
      (concat `id` intersperse ", " (map show es) ++) . (']':)
    where fromSVar (SVar str) = Just str
          fromSVar _          = Nothing
  showsPrec _ (Enum fr tn to) = ('[':) . showString (prettyExpr fr) . 
    showsMaybe (((',':) . prettyExpr) `fmap` tn) . (".."++) . 
    showsMaybe (prettyExpr `fmap` to) . (']':)
      where showsMaybe = maybe id (++)
  showsPrec _ (SLet ds e) = ("let "++) . showString (prettyDecls ds ++ " in ") . shows e


  showsPrec p (SInfix fx e1 e2) = showParen (p > fixity) $
    showsPrec f1 e1 . (' ':) . (getInfName fx++) . (' ':) . 
    showsPrec f2 e2 where
      fixity = snd $ lookupFix fx
      (f1, f2) = case fst $ lookupFix fx of
        AssocRight _ -> (fixity+1, fixity + infixSafe e2 (AssocLeft ()) fixity)
        AssocLeft _ -> (fixity + infixSafe e1 (AssocRight ()) fixity, fixity+1)
        AssocNone _ -> (fixity+1, fixity+1)

      -- This is a little bit awkward, but at least seems to produce no false
      -- results anymore
      infixSafe :: SExpr -> Assoc () -> Int -> Int
      infixSafe (SInfix fx'' _ _) assoc fx'
        | lookupFix fx'' == (assoc, fx') = 1
        | otherwise = 0
      infixSafe _ _ _ = 0 -- doesn't matter

prettyPrecPattern :: Int -> Pattern -> ShowS
prettyPrecPattern _ (PVar v) = showString v
prettyPrecPattern _ (PTuple p1 p2) = showParen True $
  prettyPrecPattern 0 p1 . (", "++) . prettyPrecPattern 0 p2
prettyPrecPattern p (PCons p1 p2) = showParen (p>5) $
  prettyPrecPattern 6 p1 . (':':) . prettyPrecPattern 5 p2
  
isOperator :: String -> Bool
isOperator s =
  case break (== '.') s of
    (_, "") -> isUnqualOp s
    (before, _dot : rest)
      | isUnqualOp before -> isUnqualOp rest
      | isModule before -> isOperator rest
      | otherwise -> False
  where
    isModule "" = False
    isModule (c : cs) = isUpper c && all (\c -> isAlphaNum c || c `elem` ['\'', '_']) cs
    isUnqualOp s = s /= "()" && all (\c -> isSymbol c || isPunctuation c) s

getInfName :: String -> String
getInfName str = if isOperator str then str else "`"++str++"`"

getPrefName :: String -> String
getPrefName str = if isOperator str || ',' `elem` str then "("++str++")" else str

{-
instance Show Assoc where
  show AssocLeft  = "AssocLeft"
  show AssocRight = "AssocRight"
  show AssocNone  = "AssocNone"

instance Ord Assoc where
  AssocNone <= _ = True
  _ <= AssocNone = False
  AssocLeft <= _ = True
  _ <= AssocLeft = False
  _ <= _ = True
-}
