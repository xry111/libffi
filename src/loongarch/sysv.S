/* -----------------------------------------------------------------------
   ffi.c - Copyright (c) 2015 Michael Knyszek <mknyszek@berkeley.edu>
                         2015 Andrew Waterman <waterman@cs.berkeley.edu>
                         2018 Stef O'Rear <sorear2@gmail.com>
                         2021 Xi Ruoyao <xry111@mengyan1223.wang>

   LoongArch Foreign Function Interface

   Permission is hereby granted, free of charge, to any person obtaining
   a copy of this software and associated documentation files (the
   ``Software''), to deal in the Software without restriction, including
   without limitation the rights to use, copy, modify, merge, publish,
   distribute, sublicense, and/or sell copies of the Software, and to
   permit persons to whom the Software is furnished to do so, subject to
   the following conditions:

   The above copyright notice and this permission notice shall be included
   in all copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED ``AS IS'', WITHOUT WARRANTY OF ANY KIND,
   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
   NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
   DEALINGS IN THE SOFTWARE.
   ----------------------------------------------------------------------- */

#define LIBFFI_ASM
#include <fficonfig.h>
#include <ffi.h>

/* Define aliases so that we can handle all ABIs uniformly */

#if _LOONGARCH_SIM == _ABILP64
#define PTRS 8
#define LARG ld.d
#define SARG st.d
#define ADDI addi.d
#elif _LOONGARCH_SIM == _ABILP32
#define PTRS 4
#define LARG ld.w
#define SARG st.w
#define ADDI addi.w
#else
#error "Unknown LoongArch ABI"
#endif

#define FLTS 8
#define FLARG fld.d
#define FSARG fst.d

    .text
    .globl  ffi_call_asm
    .type   ffi_call_asm, @function
    .hidden ffi_call_asm
/*
  struct call_context {
      floatreg fa[8];
      intreg a[8];
      intreg save_fp, save_ra;
  }
  void ffi_call_asm (size_t *stackargs, struct call_context *regargs,
                     void (*fn) (void), void *closure);
*/

#define FRAME_LEN (8 * FLTS + 10 * PTRS)

ffi_call_asm:
    .cfi_startproc

    /*
      We are NOT going to set up an ordinary stack frame.  In order to pass
      the stacked args to the called function, we adjust our stack pointer to
      a0, which is in the _caller's_ alloca area.  We establish our own stack
      frame at the end of the call_context.

      Anything below the arguments will be freed at this point, although we
      preserve the call_context so that it can be read back in the caller.
    */

    .cfi_def_cfa 5, FRAME_LEN # interim CFA based on a1
    SARG    $fp, $a1, FRAME_LEN - 2*PTRS
    .cfi_offset 22, -2*PTRS
    SARG    $ra, $a1, FRAME_LEN - 1*PTRS
    .cfi_offset 1, -1*PTRS

    ADDI    $fp, $a1, FRAME_LEN
    ADDI    $sp, $a0, 0
    .cfi_def_cfa 22, 0 # our frame is fully set up

    # Load arguments
    ADDI    $t0, $a2, 0
    ADDI    $t1, $a3, 0 # used by ffi_go_closure_asm

#if FLTS
    FLARG   $fa0, $fp, -FRAME_LEN+0*FLTS
    FLARG   $fa1, $fp, -FRAME_LEN+1*FLTS
    FLARG   $fa2, $fp, -FRAME_LEN+2*FLTS
    FLARG   $fa3, $fp, -FRAME_LEN+3*FLTS
    FLARG   $fa4, $fp, -FRAME_LEN+4*FLTS
    FLARG   $fa5, $fp, -FRAME_LEN+5*FLTS
    FLARG   $fa6, $fp, -FRAME_LEN+6*FLTS
    FLARG   $fa7, $fp, -FRAME_LEN+7*FLTS
#endif

    LARG    $a0, $fp, -FRAME_LEN+8*FLTS+0*PTRS
    LARG    $a1, $fp, -FRAME_LEN+8*FLTS+1*PTRS
    LARG    $a2, $fp, -FRAME_LEN+8*FLTS+2*PTRS
    LARG    $a3, $fp, -FRAME_LEN+8*FLTS+3*PTRS
    LARG    $a4, $fp, -FRAME_LEN+8*FLTS+4*PTRS
    LARG    $a5, $fp, -FRAME_LEN+8*FLTS+5*PTRS
    LARG    $a6, $fp, -FRAME_LEN+8*FLTS+6*PTRS
    LARG    $a7, $fp, -FRAME_LEN+8*FLTS+7*PTRS

    /* Call */
    jirl    $ra, $t0, 0

    /* Save return values - only a0/a1 (fa0/fa1) are used */
#if FLTS
    FSARG   $fa0, $fp, -FRAME_LEN+0*FLTS
    FSARG   $fa1, $fp, -FRAME_LEN+1*FLTS
#endif

    SARG    $a0, $fp, -FRAME_LEN+8*FLTS+0*PTRS
    SARG    $a1, $fp, -FRAME_LEN+8*FLTS+1*PTRS

    /* Restore and return */
    ADDI    $sp, $fp, -FRAME_LEN
    .cfi_def_cfa 3, FRAME_LEN
    LARG    $ra, $fp, -1*PTRS
    .cfi_restore 1
    LARG    $fp, $fp, -2*PTRS
    .cfi_restore 22
    jirl    $zero, $ra, 0
    .cfi_endproc
    .size   ffi_call_asm, .-ffi_call_asm


/*
  ffi_closure_asm. Expects address of the passed-in ffi_closure in t1.
  void ffi_closure_inner (ffi_cif *cif,
		          void (*fun) (ffi_cif *, void *, void **, void *),
		          void *user_data,
		          size_t *stackargs, struct call_context *regargs)
*/

    .globl ffi_closure_asm
    .hidden ffi_closure_asm
    .type ffi_closure_asm, @function
ffi_closure_asm:
    .cfi_startproc

    ADDI    $sp,  $sp, -FRAME_LEN
    .cfi_def_cfa_offset FRAME_LEN

    /* make a frame */
    SARG    $fp, $sp, FRAME_LEN - 2*PTRS
    .cfi_offset 22, -2*PTRS
    SARG    $ra, $sp, FRAME_LEN - 1*PTRS
    .cfi_offset 1, -1*PTRS
    ADDI    $fp, $sp, FRAME_LEN

    /* save arguments */
#if FLTS
    FSARG   $fa0, $sp, 0*FLTS
    FSARG   $fa1, $sp, 1*FLTS
    FSARG   $fa2, $sp, 2*FLTS
    FSARG   $fa3, $sp, 3*FLTS
    FSARG   $fa4, $sp, 4*FLTS
    FSARG   $fa5, $sp, 5*FLTS
    FSARG   $fa6, $sp, 6*FLTS
    FSARG   $fa7, $sp, 7*FLTS
#endif

    SARG    $a0, $sp, 8*FLTS+0*PTRS
    SARG    $a1, $sp, 8*FLTS+1*PTRS
    SARG    $a2, $sp, 8*FLTS+2*PTRS
    SARG    $a3, $sp, 8*FLTS+3*PTRS
    SARG    $a4, $sp, 8*FLTS+4*PTRS
    SARG    $a5, $sp, 8*FLTS+5*PTRS
    SARG    $a6, $sp, 8*FLTS+6*PTRS
    SARG    $a7, $sp, 8*FLTS+7*PTRS

    /* enter C */
    LARG    $a0, $t1, FFI_TRAMPOLINE_SIZE+0*PTRS
    LARG    $a1, $t1, FFI_TRAMPOLINE_SIZE+1*PTRS
    LARG    $a2, $t1, FFI_TRAMPOLINE_SIZE+2*PTRS
    ADDI    $a3, $sp, FRAME_LEN
    ADDI    $a4, $sp, 0

    bl      ffi_closure_inner

    /* return values */
#if FLTS
    FLARG   $fa0, $sp, 0*FLTS
    FLARG   $fa1, $sp, 1*FLTS
#endif

    LARG    $a0, $sp, 8*FLTS+0*PTRS
    LARG    $a1, $sp, 8*FLTS+1*PTRS

    /* restore and return */
    LARG    $ra, $sp, FRAME_LEN-1*PTRS
    .cfi_restore 1
    LARG    $fp, $sp, FRAME_LEN-2*PTRS
    .cfi_restore 22
    ADDI    $sp, $sp, FRAME_LEN
    .cfi_def_cfa_offset 0
    jirl    $zero, $ra, 0
    .cfi_endproc
    .size ffi_closure_asm, .-ffi_closure_asm

/*
  ffi_go_closure_asm.  Expects address of the passed-in ffi_go_closure in t1.
  void ffi_closure_inner (ffi_cif *cif,
		          void (*fun) (ffi_cif *, void *, void **, void *),
		          void *user_data,
		          size_t *stackargs, struct call_context *regargs)
*/

    .globl ffi_go_closure_asm
    .hidden ffi_go_closure_asm
    .type ffi_go_closure_asm, @function
ffi_go_closure_asm:
    .cfi_startproc

    ADDI    $sp,  $sp, -FRAME_LEN
    .cfi_def_cfa_offset FRAME_LEN

    /* make a frame */
    SARG    $fp, $sp, FRAME_LEN - 2*PTRS
    .cfi_offset 22, -2*PTRS
    SARG    $ra, $sp, FRAME_LEN - 1*PTRS
    .cfi_offset 1, -1*PTRS
    ADDI    $fp, $sp, FRAME_LEN

    /* save arguments */
#if FLTS
    FSARG   $fa0, $sp, 0*FLTS
    FSARG   $fa1, $sp, 1*FLTS
    FSARG   $fa2, $sp, 2*FLTS
    FSARG   $fa3, $sp, 3*FLTS
    FSARG   $fa4, $sp, 4*FLTS
    FSARG   $fa5, $sp, 5*FLTS
    FSARG   $fa6, $sp, 6*FLTS
    FSARG   $fa7, $sp, 7*FLTS
#endif

    SARG    $a0, $sp, 8*FLTS+0*PTRS
    SARG    $a1, $sp, 8*FLTS+1*PTRS
    SARG    $a2, $sp, 8*FLTS+2*PTRS
    SARG    $a3, $sp, 8*FLTS+3*PTRS
    SARG    $a4, $sp, 8*FLTS+4*PTRS
    SARG    $a5, $sp, 8*FLTS+5*PTRS
    SARG    $a6, $sp, 8*FLTS+6*PTRS
    SARG    $a7, $sp, 8*FLTS+7*PTRS

    /* enter C */
    LARG    $a0, $t1, 1*PTRS
    LARG    $a1, $t1, 2*PTRS
    ADDI    $a2, $t1, 0
    ADDI    $a3, $sp, FRAME_LEN
    ADDI    $a4, $sp, 0

    bl      ffi_closure_inner

    /* return values */
#if FLTS
    FLARG   $fa0, $sp, 0*FLTS
    FLARG   $fa1, $sp, 1*FLTS
#endif

    LARG    $a0, $sp, 8*FLTS+0*PTRS
    LARG    $a1, $sp, 8*FLTS+1*PTRS

    /* restore and return */
    LARG    $ra, $sp, FRAME_LEN-1*PTRS
    .cfi_restore 1
    LARG    $fp, $sp, FRAME_LEN-2*PTRS
    .cfi_restore 22
    ADDI    $sp, $sp, FRAME_LEN
    .cfi_def_cfa_offset 0
    jirl    $zero, $ra, 0
    .cfi_endproc
    .size ffi_go_closure_asm, .-ffi_go_closure_asm
