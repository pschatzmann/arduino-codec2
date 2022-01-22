/* 
  FILE...: ldpc_dec.c
  AUTHOR.: Matthew C. Valenti, Rohit Iyer Seshadri, David Rowe, Don Reid
  CREATED: Sep 2016

  Command line C LDPC decoder derived from MpDecode.c in the CML
  library.  Allows us to run the same decoder in Octave and C.  The
  code is defined by the parameters and array stored in the include
  file below, which can be machine generated from the Octave function
  ldpc_fsk_lib.m:ldpc_decode()

  The include file also contains test input/output vectors for the LDPC
  decoder for testing this program.  If no input file "stm_in.raw" is found
  then the built in test mode will run.

  If there is an input is should be encoded data from the x86 ldpc_enc
  program.  Here is the suggested way to run:

    ldpc_enc /dev/zero stm_in.raw --sd --code HRA_112_112 --testframes 6

    ldpc_dec stm_in.raw ref_out.raw --sd --code HRA_112_112 --testframes 

    <Load stm32 and run>

    cmp -l ref_out.raw stm_out.raw
    << Check BER values in logs >>
*/

#include <assert.h>
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

#include "mpdecode_core.h"
#include "ofdm_internal.h"

#include "semihosting.h"
#include "stm32f4xx_conf.h"
#include "stm32f4xx.h"
#include "machdep.h"
#include "ldpc_codes.h"
#include "memtools.h"

int testframes = 1;

//static char fin_buffer[1024];
//static __attribute__ ((section (".ccm"))) char fout_buffer[8*8192];

int main(int argc, char *argv[]) {    
    int         CodeLength, NumberParityBits;
    int         i, parityCheckCount;
    int         data_bits_per_frame;
    FILE        *fout;
    int         iter, total_iters;
    int         Tbits, Terrs, Tbits_raw, Terrs_raw;

    int   nread, frame;

    semihosting_init();

    fprintf(stderr, "LDPC decode test and profile\n");
    memtools_find_unused(printf);
    
    PROFILE_VAR(ldpc_decode);
    machdep_profile_init();

    char code_name[255] = "HRAb_396_504";
    struct LDPC ldpc;
    ldpc_codes_setup(&ldpc, code_name);
    ldpc.max_iter = 5;
    
    CodeLength = ldpc.CodeLength;
    NumberParityBits = ldpc.NumberParityBits;
    data_bits_per_frame = ldpc.NumberRowsHcols;
    unsigned char ibits[data_bits_per_frame];
    unsigned char pbits[NumberParityBits];
    uint8_t     out_data[CodeLength];

    testframes = 1;
    total_iters = 0;

    if (testframes) {
        uint16_t r[data_bits_per_frame];
        ofdm_rand(r, data_bits_per_frame);

        for(i=0; i<data_bits_per_frame; i++) {
            ibits[i] = r[i] > 16384;
        }
        encode(&ldpc, ibits, pbits);  
        Tbits = Terrs = Tbits_raw = Terrs_raw = 0;
    }

    FILE* fin = fopen("stm_in.raw", "rb");
    if (fin == NULL) {
        fprintf(stderr, "Error opening input file\n");
        fflush(stderr);
        exit(1);
    }
    //setvbuf(fin, fin_buffer,_IOFBF,sizeof(fin_buffer));

    fout = fopen("stm_out.raw", "wb");
    if (fout == NULL) {
        fprintf(stderr, "Error opening output file\n");
        fflush(stderr);
        exit(1);
    }
    //setvbuf(fout, fout_buffer,_IOFBF,sizeof(fout_buffer));

    float  *input_float  = calloc(CodeLength, sizeof(float));

    nread = CodeLength;
    fprintf(stderr, "CodeLength: %d\n", CodeLength);

    frame = 0;
    while(fread(input_float, sizeof(float) , nread, fin) == nread) {
       fprintf(stderr, "frame %d\n", frame);

       if (testframes) {
            char in_char;
            for (i=0; i<data_bits_per_frame; i++) {
                in_char = input_float[i] < 0;
                if (in_char != ibits[i]) {
                    Terrs_raw++;
                }
                Tbits_raw++;
            }
            for (i=0; i<NumberParityBits; i++) {
                in_char = input_float[i+data_bits_per_frame] < 0;
                if (in_char != pbits[i]) {
                    Terrs_raw++;
                }
                Tbits_raw++;
            }
        }
        float *llr = input_float;
        sd_to_llr(llr, input_float, CodeLength);

        PROFILE_SAMPLE(ldpc_decode);
        iter = run_ldpc_decoder(&ldpc, out_data, llr, &parityCheckCount);
        PROFILE_SAMPLE_AND_LOG2(ldpc_decode, "ldpc_decode");
        //fprintf(stderr, "iter: %d\n", iter);
        total_iters += iter;

        fwrite(out_data, sizeof(char), data_bits_per_frame, fout);

        if (testframes) {
            for (i=0; i<data_bits_per_frame; i++) {
                if (out_data[i] != ibits[i]) {
                    Terrs++;
                    //fprintf(stderr, "%d %d %d\n", i, out_data[i], ibits[i]);
                }
                Tbits++;
            }
        }

        frame++;
    }

    fclose(fin);
    fclose(fout);

    fprintf(stderr, "total iters %d\n", total_iters);
    
    if (testframes) {
        fprintf(stderr, "Raw Tbits..: %d Terr: %d BER: %4.3f\n", 
                Tbits_raw, Terrs_raw, (double)(Terrs_raw/(Tbits_raw+1E-12)));
        fprintf(stderr, "Coded Tbits: %d Terr: %d BER: %4.3f\n", 
                Tbits, Terrs, (double)(Terrs/(Tbits+1E-12)));
    }
        
    printf("\nStart Profile Data\n");
    machdep_profile_print_logged_samples();
    printf("End Profile Data\n");

    fclose(stdout);
    fclose(stderr);

    return 0;
}

/* vi:set ts=4 et sts=4: */
