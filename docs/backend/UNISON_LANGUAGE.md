# Unison Programming Language Guide

Unison is a statically typed functional language with typed effects. This guide is the repo-local authoritative reference for core syntax, semantics, and style.

## Core Language Features

Unison is a statically typed functional programming language with typed effects (called "abilities" or algebraic effects). It uses strict evaluation (not lazy by default) and has proper tail calls for handling recursion.

## Function Syntax

Functions in Unison follow an Elm-style definition with type signatures on a separate line:

```
factorial : Nat -> Nat
factorial n = product (range 1 (n + 1))
```

## Binary operators

Binary operators are just functions written with infix syntax like `expr1 * expr2` or `expr1 Text.++ expr2`.

Any operator can also be written with prefix syntax. The only common use is passing an operator as an argument:

```
sum = List.foldLeft (Nat.+) 0
product = List.foldLeft (Nat.*) 1
dotProduct = Nat.sum (List.zipWith (*) [1,2,3] [4,5,6])
```

IMPORTANT: when passing an operator as an argument to a higher order function, surround it in parens.

### Currying and Multiple Arguments

Functions are automatically curried. Arrow types associate to the right.

```
add : Nat -> Nat -> Nat
add x y = x + y

add5 : Nat -> Nat
add5 = add 5
```

## Lambdas

Anonymous functions are written like `x -> x + 1` or `x y -> x + y * 2`.

CORRECT:

```
List.zipWith (x y -> x * 10 + y) [1,2,3] [4,5,6]
```

INCORRECT:

```
List.zipWith (x -> y -> x * 10 + y) [1,2,3] [4,5]
```

## Type Variables and Quantification

Lowercase variables in signatures are implicitly universally quantified.

```
map : (a -> b) -> [a] -> [b]
```

Prefer implicit quantification. Use explicit `forall` only for higher-rank functions.

## Algebraic Data Types

```
type Optional a = None | Some a

type Either a b = Left a | Right b
```

### Prefer using `cases` where possible

```
Optional.map : (a -> b) -> Optional a -> Optional b
Optional.map f = cases
  None -> None
  Some a -> Some (f a)
```

The `cases` syntax is also useful for tuples and multi-argument functions.

### Rules on Unison pattern matching syntax

You CANNOT pattern match on the left side of `=`.

INCORRECT:

```
List.head : [a] -> Optional a
List.head [] = None
List.head (hd +: _tl) = Some hd
```

CORRECT:

```
List.head : [a] -> Optional a
List.head = cases
  [] -> None
  hd +: _tl -> Some hd
```

### Important naming convention

Unison uses `None` / `Some`, not `Nothing` / `Just`.

Prefer short variable names for helpers:

- `rem`
- `acc`
- `go`
- `loop`
- `f`
- `g`

## Lists

```
[1,2,3]
[1,2,3] :+ 4
0 +: [1,2,3]
[1,2,3] ++ [4,5,6]
```

Pattern examples:

```
match xs with
  [1,2,3] ++ rem -> transmogrify rem
  init ++ [1,2,3] -> frobnicate init
  init :+ last -> wrangle last
  [] -> 0
```

Lists are finger trees. Appending at the end with `:+` is efficient.

IMPORTANT: do not build lists in reverse order and call `List.reverse` at the end.

## Use accumulating parameters and tail recursive functions for looping

```
Nat.sum : [Nat] -> Nat
Nat.sum ns =
  go acc = cases
    [] -> acc
    x +: xs -> go (acc + x) xs
  go 0 ns
```

If you are writing a function over a list, prefer tail recursion with an accumulating parameter.

## Build up lists in order

CORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as =
  go acc = cases
    [] -> acc
    x +: xs -> go (acc :+ f x) xs
  go [] as
```

INCORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as =
  go acc = cases
    [] -> List.reverse acc
    x +: xs -> go (f x +: acc) xs
  go [] as
```

## Abilities (Algebraic Effects)

```
Optional.map : (a ->{g} b) -> Optional a ->{g} Optional b
```

### Defining abilities

```
ability Exception where
  raise : Failure -> x
```

### Using abilities

```
printLine : Text ->{IO, Exception} ()
```

### Handling abilities

```
Exception.toEither : '{g, Exception} a ->{g} Either Failure a
Exception.toEither a =
  handle a()
  with cases
    { a } -> Right a
    { Exception.raise f -> resume } -> Left f
```

### Ability handler style guidelines

1. Use `go` or `loop` for recursive helpers.
2. Keep handler state in function arguments.
3. For handlers that resume continuations, structure them explicitly.
4. Inline very small expressions used once.
5. Use `do` instead of `'` within function bodies to create thunks.

## Effect and State Management

```
Stream.toList : '{g, Stream a} () ->{g} [a]
Stream.toList sa =
  go acc req = match req with
    { () } -> acc
    { Stream.emit a -> resume } ->
      handle resume() with go (acc :+ a)
  handle sa() with go []
```

## Record Types

```
type Employee = { name : Text, age : Nat }
```

This generates accessor functions and updaters.

### Important: record access syntax

Use generated functions, not dot field access:

```
Ring.zero ring
```

not:

```
ring.zero
```

## Namespaces and Imports

```
use List map filter
```

Wildcard import:

```
use List
```

## Collection Operations

```
a +: as
as :+ a
[x,y] ++ rem
```

### List functions and ability polymorphism

CORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
```

INCORRECT:

```
List.map : (a -> b) -> [a] -> [b]
```

## Pattern Matching with Guards

```
List.filter : (a -> Boolean) -> [a] -> [a]
List.filter p as =
  go acc rem = match rem with
    [] -> acc
    a +: as | p a -> go (acc :+ a) as
            | otherwise -> go acc as
  go [] as
```

### Guard style convention

Align follow-on guards vertically under the first guard for the same pattern.

## Block Structure and Binding

Blocks are introduced by `->` and can contain multiple bindings followed by an expression.

### Important: no `let` keyword

CORRECT:

```
nextAcc = Ring.add ring acc (Ring.mul ring x y)
```

### No `where` clauses

Define helper functions in the main block before use.

## Error Handling

Unison uses the `Exception` ability for error handling.

## Text Handling

Unison calls strings `Text` and uses `++` for concatenation.

### No string interpolation

Use concatenation with `++`.

## The Pipeline Operator `|>`

`x |> f` is equivalent to `f x`.

## Writing documentation

Documentation blocks appear just before the function or type they document.

## Type System Without Typeclasses

Unison uses explicit dictionary passing instead of typeclasses.

## Program Entry Points

```
main : '{IO, Exception} ()
main = do printLine "hello, world!"
```

Use UCM to run or compile programs.

## Testing

```
test> Nat.tests.props = test.verify do
  Each.repeat 100
  n = Random.natIn 0 1000
  m = Random.natIn 0 1000
  labeled "addition is commutative" do
    ensureEqual (n + m) (m + n)
```

Tests for a function or type `foo` should be named `foo.tests.<test-name>`.

## Lazy Evaluation

Unison is strict by default. Use `do` for delayed computations.

### Strict evaluation

Delayed operations must be forced with `()` or `!` when you need them to run.

## Standard Library

Common structures include:

- `List`
- `Map`
- `Set`
- `Pattern`

## Additional Resources

- Unison docs on regex patterns: https://share.unison-lang.org/@unison/base/code/main/latest/types/Pattern
- Testing documentation: https://share.unison-lang.org/@unison/base/code/main/latest/terms/test/verify
