# Calculadora Científica — TipOS

Calculadora científica interativa para o [TipOS](https://github.com/TipGroup-inc/TipOS-staging). Freestanding ELF64, sem libc, syscalls via `int $0x80`.

## Compilando

```bash
zig build
```

Saída: `zig-out/bin/calc`

## Instalando no disco

```bash
mcopy -o -i disk.img ../TipOS-programs/calculadoraCientifica/zig-out/bin/calc ::/BIN/CALC
make run-curses
```

No shell `MkM>`:

```
exec CALC
```

## Uso

```
calc> 2 + 3
5

calc> sin(pi / 2)
1

calc> sqrt(144)
12

calc> 2 ^ 10
1024

calc> ln(2.718281828)
1

calc> exit
```

## Operadores

| Operador | Descrição |
|----------|-----------|
| `+` | Soma |
| `-` | Subtração / unário |
| `*` | Multiplicação |
| `/` | Divisão |
| `%` | Módulo |
| `^` | Potência |
| `()` | Parênteses |

## Funções

| Função | Descrição | Exemplo |
|--------|-----------|---------|
| `sin(x)` | Seno (radianos) | `sin(0)` → `0` |
| `cos(x)` | Cosseno (radianos) | `cos(0)` → `1` |
| `tan(x)` | Tangente (radianos) | `tan(pi/4)` → `1` |
| `asin(x)` | Arco seno [-1, 1] | `asin(1)` → `1.5707...` |
| `acos(x)` | Arco cosseno [-1, 1] | `acos(1)` → `0` |
| `atan(x)` | Arco tangente | `atan(1)` → `0.7853...` |
| `log(x)` | Logaritmo base 10 | `log(100)` → `2` |
| `ln(x)` | Logaritmo natural | `ln(e)` → `1` |
| `sqrt(x)` | Raiz quadrada | `sqrt(9)` → `3` |
| `abs(x)` | Valor absoluto | `abs(-5)` → `5` |

## Constantes

| Nome | Valor |
|------|-------|
| `pi` | 3.14159265358979... |

## Detalhes Técnicos

- **Target:** x86_64-freestanding
- **Entry point:** `_start` (não `main`)
- **Syscalls:** `int $0x80` (`rax`=nº, `rdi`=a1, `rsi`=a2, `rdx`=a3)
- **Parser:** recursive descent com precedência (add/sub → mul/div/mod → power → unary → primary)
- **Matemática:** toda implementada do zero — Taylor series (sin/cos), polinômio racional (atan), decomposição IEEE 754 (ln), Newton-Raphson (sqrt)
- **Build:** `zig build` (`ReleaseSmall`, freestanding)
