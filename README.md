<!-- moe moe kyun <3 -->
# TipOS-programs — programas nativos do TipOS

Aqui moram os **programas nativos** que rodam no [TipOS](https://github.com/TipGroup-inc/TipOS-staging)
(kernel próprio em C + NASM + Zig). Cada programa roda em **ring 3** (userland),
chamando o kernel via syscalls `int 0x80`.

> O kernel (loader, syscalls, shell) fica no **TipOS-staging**. Este repo é só
> a cozinha dos apps: o código, o build e o tutorial de como fazer.

## Como um programa roda

1. Você compila um **ELF executável** (sem libc do host)
2. O ELF vai pro `disk.img` (instalado pelo Makefile raiz do TipOS-staging, que
   espera este repo em `../TipOS-programs` — igual `disp` e `term`)
3. No shell `MkM>`: `exec NOMEDOPROG` (ou `exec /BIN/NOMEDOPROG`)
4. O kernel carrega o ELF64 (`elf64.zig`), cria o processo em ring 3 com TSS,
   e o programa usa `int 0x80` pra conversar com o kernel

**Dois jeitos de escrever:**

| Caminho | Linguagem | libc | Exemplo |
|---------|-----------|------|---------|
| **A (recomendado p/ novos)** | Zig | nenhuma (syscalls diretos) | `calc/` (issue #1) |
| **B (clássico)** | C | libc própria do TipOS | `graphy`, `hello` |

---

# Tutorial A: Zig freestanding → ELF (sem libc)

Programa Zig **sem nenhuma libc**: o `_start` chama os syscalls direto.

## Hello World (zig)

```zig
const std = @import("std"); // só pra tipos/compilador — nada de std.io no runtime

export fn _start() callconv(.C) noreturn {
    const msg = "Hello, TipOS!\n";
    const len = msg.len;
    // syscall write(4): rdi=fd, rsi=buf, rdx=count
    asm volatile ("int $0x80"
        : "+a" (@as(usize, 4))
        : [fd] "D" (@as(usize, 1)),
          [buf] "S" (@as(usize, @intFromPtr(msg.ptr))),
          [n] "d" (@as(usize, len))
        : "rcx", "r11", "memory");
    // syscall exit(1): rdi=code
    asm volatile ("int $0x80"
        : "+a" (@as(usize, 1))
        : [code] "D" (@as(usize, 0))
        : "rcx", "r11");
    unreachable;
}
```

**Atenção**: sem libc não existe `main` — o entry point é o `_start`
(assim como no `crt0.c` do TipOS). O loader `elf64.zig` pula pro `_start`.

## Compilando

```bash
zig build-exe src/calc.zig \
    -target x86_64-freestanding \
    -mno-red-zone \
    -O ReleaseSmall \
    -femit-bin=build/calc
```

- `x86_64-freestanding` = sem libc, sem features de host
- `-fno-red-zone` = regra do kernel (interrupções usam a stack)
- Build final pode virar um `build.zig` (issue #1 pede isso)

## Instalando no disco + rodando

```bash
# do repo TipOS-staging (que tem o Makefile raiz e o disk.img)
mcopy -o -i disk.img ../TipOS-programs/build/calc ::/BIN/CALC
make run-curses
# no shell:  exec CALC
```

---

# Tutorial B: C com libc própria

A libc do TipOS (`src/userland/libc` no staging) é pequena e MIT — dá
`printf`, `fopen`, `malloc`, teclado e o resto. Fluxo completo:

## 1. Hello World

Crie `src/userland/progs/hello.c` (no staging):

```c
#include <stdio.h>

int main(int argc, char **argv) {
    printf("Hello, TipOS!\n");
    return 0;
}
```

O `return 0` chama `exit(1)` via `_start` (em `crt0.c`).

## 2. Compilando

Adicione `hello` no Makefile (`src/userland/Makefile`):

```makefile
PROGS = graphy hello
```

O Makefile compila cada programa em `progs/` com:
- `-ffreestanding -nostdlib -static -fno-PIC -mno-red-zone`
- `-nostartfiles -O1 -I include`
- Linker script `libc/link.ld` (entry `_start`, código em `0x2000000`)
- `macho_pack.py` empacota como Mach-O 64-bit minimal

```bash
make -C src/userland install
```

Isso gera `build/userland/hello.macho` e copia pro disco
(nome FAT32 maiúsculo: `HELLO`).

## 3. Rodando no QEMU

```bash
make run-curses
```

No shell `MkM>`, digite:

```
HELLO
```

(O shell busca em `/BIN/`; ou explícito: `exec /BIN/HELLO`.)

## 4. API da libc (resumo)

### stdio.h

```c
int open(const char *path, int flags);
int close(int fd);
int read(int fd, void *buf, int count);
int write(int fd, const void *buf, int count);
int lseek(int fd, int offset, int whence);
int unlink(const char *path);
int mkdir(const char *path);
int rmdir(const char *path);
int stat(const char *path, struct stat *buf);
int fstat(int fd, struct stat *buf);
int kbhit(void);            // 1 se tecla disponível, 0 senão

void putchar(char c);
void puts(const char *s);
int printf(const char *fmt, ...);
int vsnprintf(char *buf, int n, const char *fmt, va_list ap);
int sprintf(char *buf, const char *fmt, ...);
int sscanf(const char *s, const char *fmt, ...);
char getchar(void);         // blocking
char *gets(char *buf);
char *fgets(char *buf, int n, FILE *f);

FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
int fread(void *buf, int size, int count, FILE *f);
int fwrite(const void *buf, int size, int count, FILE *f);
int fputs(const char *s, FILE *f);
int fputc(int c, FILE *f);
int fprintf(FILE *f, const char *fmt, ...);
```

**Nota**: `FILE` é um wrapper em volta do fd.
`fopen("r")` = `open()` com `O_RDONLY`, `"w"` = `O_WRONLY|O_CREAT`.

### stdlib.h

```c
void *malloc(size_t size);   // bump allocator (nunca libera)
void free(void *p);          // noop
int atoi(const char *s);
void exit(int code);         // syscall 1
long strtol(const char *s, char **end, int base);
```

### string.h / ctype.h / sys/stat.h

`memset/memcpy/memmove/memcmp/strlen/strcmp/strncmp/strcpy/strncpy/strcat/strchr/strstr/strtok`
e `isdigit/isspace/isalpha/isalnum/isxdigit/isupper/islower/toupper/tolower`,
`struct stat { unsigned int st_size; unsigned int st_mode; }` (st_mode: 1=dir, 0=arquivo).

## 5. Teclado

`getchar()` bloqueia até uma tecla; `kbhit()` é non-blocking.
Teclas especiais (setas, F-keys...) chegam como **sequências VT100**
começando com `\x1b` (ESC). Parser de exemplo no `graphy.c`.

| Tecla | Sequência |
|-------|-----------|
| ↑ | `\x1b[A` |
| ↓ | `\x1b[B` |
| ← | `\x1b[D` |
| → | `\x1b[C` |
| Home/End | `\x1b[H` / `\x1b[F` |
| PgUp/PgDn | `\x1b[5~` / `\x1b[6~` |
| Insert/Delete | `\x1b[2~` / `\x1b[3~` |
| F1–F4 | `\x1bOP`–`\x1bOS` |
| F5–F12 | `\x1b[15~` … `\x1b[24~` |

## 6. Terminal (VGA) e ANSI

`write(1, ...)` / `printf` escreve no terminal. O driver interpreta ANSI/VT100
básico: `\x1b[H` (home), `\x1b[<r>;<c>H` (posiciona), `\x1b[2J` (limpa),
`\x1b[K`, `\x1b[7m` (reverse), `\x1b[m`, `\x1b[?25l/h` (cursor).

Exemplo — barra de status em video reverso:

```c
write(1, "\x1b[7m", 4);      // liga reverse
write(1, "--- status ---", 14);
write(1, "\x1b[m\n", 4);     // desliga reverse
```

## 7. Arquivos (FAT32)

```c
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    FILE *f = fopen("/BIN/HELLO.TXT", "w");
    if (f) {
        fputs("Hello, file!\n", f);
        fclose(f);
    }
    f = fopen("HELLO.TXT", "r");   // relativo ao CWD
    if (f) {
        char buf[256];
        int n = fread(buf, 1, 255, f);
        buf[n] = 0;
        printf("Lido: %s\n", buf);
        fclose(f);
    }
    return 0;
}
```

**Notas**: nomes FAT32 são 8.3 maiúsculo; caminhos absolutos começam com `/`;
sem path traversal (`..`); o shell começa em `/`.

---

# Syscalls (int 0x80)

Convenção: `rax`=nº, `rdi`=a1, `rsi`=a2, `rdx`=a3, `rcx`=a4. Retorno em `rax`.
Tabela completa: seção "Syscalls (int 0x80)" do README do TipOS-staging.
Os principais pra apps:

| Nº | Nome | rdi | rsi | rdx |
|----|------|-----|-----|-----|
| 1 | exit | code | - | - |
| 3 | read | fd | buffer | count |
| 4 | write | fd | buf | count |
| 5 | open | path | flags | mode |
| 6 | close | fd | - | - |
| 198 | kbhit | - | - | - |
| 199 | lseek | fd | offset | whence |

> Compat Linux: o kernel também carrega ELF **musl** e traduz syscalls
> (`read=0→3`, `write=1→4`, `exit_group=231→1`, ...).

# Dicas e limitações

- **Ring 3**: programa roda em ring 3 com TSS (processos têm PCB próprio,
  scheduler RR no kernel). Syscall maluca não derruba o kernel sozinha,
  mas um program bugado pode travar o processo (ou, se explorar bug no
  kernel, o sistema).
- **Stack**: evite arrays locais gigantes; prefira `static`/`malloc`.
- **malloc** (libc): bump allocator simples, nunca libera.
- **BSS**: zerado pelo `crt0.c` no boot do processo.
- **Exit**: `return 0` da `main` → `exit(1)`. Em Zig, `_start` chama `exit` direto.
- **Nomes FAT32**: 8.3 maiúsculo. `mcopy` já converte.

---

Veja o `graphy.c` (no staging, `src/userland/progs/`) pra um exemplo completo
de editor TUI com scroll, busca e atalhos. Docs: `AGENTS.md`, `KERNEL.md`,
`docs/uml/` (diagramas) e `TUTORIAL_APPS.txt` (protocolo dos apps gráficos,
repo irmão `disp`) — tudo no **TipOS-staging**. moe moe kyun <3