% vq_compare.m
% David Rowe Sep 2021
%
% Compare the Eb/No performance of Vector Quantisers (robustness to bit errors) using
% Spectral Distortion (SD) measure.

#{
  usage:

  1. Generate the initial VQ (vq_stage1.f32) and input test vector file (all_speech_8k_lim.f32):
 
    cd codec2/build_linux
    ../script/train_trellis.sh

  2. Run the Psuedo-Gray binary switch tool to optimise the VQ against single bit errors:

    ./misc/vq_binary_switch -d 20 vq_stage1.f32 vq_stage1_bs001.f32 -m 5000 --st 2 --en 16 -f

    This can take a while, but if you ctrl-C at any time it will have saved the most recent optimised VQ.
   
  3. Run this script to compare the two VQs:

    octave:34> vq_compare
#}


function vq_compare(action="run_curves", vq_fn, dec=1, EbNodB=3, in_fn, out_fn)
  more off;
  randn('state',1);

  if strcmp(action, "run_curves")
    run_curves(30*100);
  end
  if strcmp(action, "vq_file")
    vq_file(vq_fn, dec, EbNodB, in_fn, out_fn)
  end
endfunction


% -------------------------------------------------------------------

% converts a decimal value to a soft dec binary value
function c = dec2sd(dec, nbits)
    
    % convert to binary

    c = zeros(1,nbits);
    for j=0:nbits-1
      mask = 2.^j;
      if bitand(dec,mask)
        c(nbits-j) = 1;
      end
    end

    % map to +/- 1

    c = -1 + 2*c;
endfunction

% fast version of vector quantiser
function [indexes target_] = vector_quantiser_fast(vq, target, verbose=1)
  [vq_size K] = size(vq);
  [ntarget tmp] = size(target);
  target_ = zeros(ntarget,K);
  indexes = zeros(1,ntarget);

  % pre-compute energy of each VQ vector
  vqsq = zeros(vq_size,1);
  for i=1:vq_size
    vqsq(i) = vq(i,:)*vq(i,:)';
  end

  % use efficient matrix multiplies to search for best match to target
  for i=1:ntarget
    best_e = 1E32;
    e = vqsq - 2*(vq * target(i,:)');
    [best_e best_ind] = min(e);
    if verbose printf("best_e: %f best_ind: %d\n", best_e, best_ind), end;
    target_(i,:) = vq(best_ind,:); indexes(i) = best_ind;
  end
endfunction


% VQ a target sequence of frames then run a test using vanilla uncoded/trellis decoder
function results = run_test(target, vq, EbNo, verbose)
  [frames tmp]      = size(target);
  [vq_length tmp]   = size(vq);
  nbits             = log2(vq_length);
  nerrors           = 0;
  tbits             = 0;
  nframes           = 0;
  nper              = 0;
  
  % Vector Quantise target vectors sequence
  [tx_indexes target_ ] = vector_quantiser_fast(vq, target, verbose);
  % use convention of indexes starting from 0
  tx_indexes -= 1; 
  %  mean SD of VQ with no errors
  diff = target - target_;
  mse_noerrors = mean(diff(:).^2);
  
  % construct tx symbol codewords from VQ indexes
  tx_codewords = zeros(frames, nbits);
  for f=1:frames
    tx_codewords(f,:) = dec2sd(tx_indexes(f), nbits);
  end

  rx_codewords = tx_codewords + randn(frames, nbits)*sqrt(1/(2*EbNo));
  rx_indexes = zeros(1,frames);

  for f=1:frames
    tx_bits        = tx_codewords(f,:) > 0;
    rx_bits        = rx_codewords(f,:) > 0;
    rx_indexes(f)  = sum(rx_bits .* 2.^(nbits-1:-1:0));
    errors         = sum(xor(tx_bits, rx_bits));
    nerrors       += errors;
    if errors nper++;, end
    tbits += nbits;
    nframes++;
  end

  EbNodB = 10*log10(EbNo);
  target_ = vq(rx_indexes+1,:);
  diff = target - target_;
  mse = mean(diff(:).^2);
  printf("Eb/No: %3.2f dB nframes: %2d nerrors: %3d BER: %4.3f PER: %3.2f mse: %3.2f %3.2f\n", 
         EbNodB, nframes, nerrors, nerrors/tbits, nper/nframes, mse_noerrors, mse);
  results.ber = nerrors/tbits;	 
  results.per = nper/nframes;	 
  results.mse_noerrors = mse_noerrors;
  results.mse = mse;
  results.tx_indexes = tx_indexes;
  results.rx_indexes = rx_indexes;
endfunction

% Simulations ---------------------------------------------------------------------

% top level function to set up and run a test with a specific vq
function [results target_] = run_test_vq(vq_fn, target_fn, nframes=100, dec=1, EbNodB=3, verbose=0)
  K = 20; K_st=2+1; K_en=16+1;
  
  % load VQ
  vq = load_f32(vq_fn, K);
  [vq_size tmp] = size(vq);
  vqsub = vq(:,K_st:K_en);
  
  % load sequence of target vectors we wish to VQ
  target = load_f32(target_fn, K);

  % limit test to the first nframes vectors
  if nframes != -1
    last = nframes;
  else
    last = length(target);
  end
  target = target(1:dec:last, K_st:K_en);
  
  % run a test
  EbNo=10^(EbNodB/10);
  results = run_test(target, vqsub, EbNo, verbose);
  if verbose
    for f=2:nframes-1
      printf("f: %03d tx_index: %04d rx_index: %04d\n", f,  results.tx_indexes(f), results.rx_indexes(f));
    end
  end

  % return full band vq-ed vectors
  target_ = zeros(last,K);
  target_(1:dec:last,:) = vq(results.rx_indexes+1,:);
  
  % use linear interpolation to restore original frame rate
  for f=1:dec:last-dec
    prev = f; next = f + dec;
    for g=prev+1:next-1
      cnext = (g-prev)/dec; cprev = 1 - cnext;
      target_(g,:) = cprev*target_(prev,:) + cnext*target_(next,:);
      %printf("f: %d g: %d cprev: %f cnext: %f\n", f, g, cprev, cnext);
    end
  end
endfunction

% generate sets of curves
function run_curves(frames=100, dec=1)
  target_fn = "../build_linux/all_speech_8k_lim.f32";
  results1_log = [];
  EbNodB = 0:5;
  for i=1:length(EbNodB)
    results = run_test_vq("../build_linux/vq_stage1.f32", target_fn, frames, dec, EbNodB(i), verbose=0);
    results1_log = [results1_log results];
  end
  results2_log = [];
  for i=1:length(EbNodB)
    results = run_test_vq("../build_linux/vq_stage1_bs001.f32", target_fn, frames, dec, EbNodB(i), verbose=0);
    results2_log = [results2_log results];
  end
  results4_log = [];
  for i=1:length(EbNodB)
    results = run_test_vq("../build_linux/vq_stage1_bs004.f32", target_fn, frames, dec, EbNodB(i), verbose=0);
    results4_log = [results4_log results];
  end
  for i=1:length(results1_log)
    ber(i) = results1_log(i).ber;
    per(i) = results1_log(i).per;
    mse_noerrors(i) = sqrt(results1_log(i).mse_noerrors);
    mse_vq1(i) = sqrt(results1_log(i).mse);
    mse_vq2(i) = sqrt(results2_log(i).mse);
    mse_vq4(i) = sqrt(results4_log(i).mse);
  end

  figure(1); clf;
  semilogy(EbNodB, ber, 'g+-;ber;','linewidth', 2); hold on;
  semilogy(EbNodB, per, 'b+-;per;','linewidth', 2);
  grid('minor'); xlabel('Eb/No(dB)');

hold off;
  
  figure(2); clf;
  plot(EbNodB, mse_noerrors, "b+-;no errors;"); hold on;
  plot(EbNodB, mse_vq1, "g+-;vanilla;");
  plot(EbNodB, mse_vq2, "r+-;binary switch;");
  plot(EbNodB, mse_vq4, "b+-;binary switch with prob;");
  hold off; grid; title("RMS SD (dB)"); xlabel('Eb/No(dB)');
endfunction


function vq_file(vq_fn, dec, EbNodB, in_fn, out_fn)
  [results target_] = run_test_vq(vq_fn, in_fn, nframes=-1, dec, EbNodB, verbose=0);
  save_f32(out_fn, target_);
endfunction

