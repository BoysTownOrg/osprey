% op_robustSpecReg.m
% Georg Oeltzschner, Johns Hopkins University 2019.
% Mark Mikkelsen, Johns Hopkins University 2019.
%
% USAGE:
% [out,fs,phs] = op_robustSpecReg(in);
%
% DESCRIPTION:
% Perform robust spectral registration in the time domain to correct frequency and
% phase drifts.
%
% INPUTS:
% in        = Input data structure.
% echo      = Return messages to the prompt? (1 = YES (default), 0 = NO)
%
% OUTPUTS:
% out       = Output following alignment of averages.
% fs        = Vector of frequency shifts (in Hz) used for alignment.
% phs       = Vector of phase shifts (in degrees) used for alignment.


function [out,fs,phs] = op_robustSpecReg(in, echo)

if nargin < 2
    echo = 1;
end

% Check whether data is coil-combined. If not, throw error.
if ~in.flags.addedrcvrs
    error('ERROR:  I think it only makes sense to do this after you have combined the channels using op_addrcvrs.  ABORTING!!');
end

% Check whether data is averaged. If it is, throw warning and return unmodified data.
if in.dims.averages == 0 || in.averages < 2
    %DO NOTHING
    warning('No averages found.  Returning input without modification!');
    out = in;
    out.flags.freqcorrected = 1;
    fs  = 0;
    phs = 0;
    return
end

% Check whether input structure has sub-spectra.
% If it does, prepare to loop over all sub-spectra. Each sub-spectrum will
% get aligned separately.
if in.dims.subSpecs == 0
    numSubSpecs = 1;
else
    numSubSpecs = in.sz(in.dims.subSpecs);
end

% Pre-allocate memory.
fs      = zeros(in.sz(in.dims.averages),numSubSpecs);
phs     = zeros(in.sz(in.dims.averages),numSubSpecs);
fids    = zeros(in.sz(in.dims.t),1,numSubSpecs);
runCount = 0;

% Optimization options
lsqnonlinopts = optimoptions(@lsqnonlin);
lsqnonlinopts = optimoptions(lsqnonlinopts,'Display','off','Algorithm','levenberg-marquardt');

% Initialize common variables and loop over sub-spectra
parsFit     = [0,0];
t           = in.t;
input.dwelltime   = in.dwelltime;

for mm=1:numSubSpecs
    %%% Automatic lipid/unstable residual water removal %%%
    freq        = in.ppm;
    waterLim = freq <= 4.68 + 0.25 & freq >= 4.68 - 0.25;
    lipidLim = freq <= 1.85 & freq >= 0;
    noiseLim = freq <= 11 & freq >= 10;
    %%% /Automatic lipid/unstable residual water removal %%%
    
    % Create a lipid-to-noise criterion from the mean unaligned data
    S = mean(in.specs(:,:,mm), 2);
    r = std(S(lipidLim)) / std(S(noiseLim));
    % Create a 'how unstable is the residual water signal?' criterion from
    % the mean unaligned data
    q = sum(abs(in.specs(waterLim,:,mm))) * abs(freq(1) - freq(2));
    q = q / max(q);
    q = sum(q < 0.4) / length(q);
    q_threshold = 0.1;
    
    % If significant lipid signal and/or unstable residual water signal is
    % present, run the Whittaker filtering in the frequency domain.
    lipid_flag = 0;
    unstable_H20_flag = 0;
    if r > 40 || q > q_threshold
        % Extract the frequency-domain sub-spectrum
        spec = in.specs(:,:,mm);
        
        % Is there excessive lipid?
        if r > 40
            lipid_flag = 1;
        end
        % Is there unstable residual water?
        if q > q_threshold
            unstable_H20_flag = 1;
        end
        
        reverseStr = '';
        
        % Loop over averages in the sub-spectrum
        for jj = 1:in.averages
            
            if echo
                if lipid_flag && ~unstable_H20_flag
                    msg = sprintf('\nLipid contamination detected. Applying lipid filter to transient: %d\n', jj);
                elseif ~lipid_flag && unstable_H20_flag
                    msg = sprintf('\nUnstable residual water detected. Applying residual water filter to transient: %d\n', jj);
                elseif lipid_flag && unstable_H20_flag
                    msg = sprintf('\nLipid contamination and unstable residual water detected. Applying lipid and residual water filters to transient: %d\n', jj);
                end
                fprintf([reverseStr, msg]);
                reverseStr = repmat(sprintf('\b'), 1, length(msg));
            end
            
            DataToAlign(:,jj) = SignalFilter(spec(:,jj), lipid_flag, unstable_H20_flag, in);
            
        end
        
        if ishandle(77)
            close(77);
        end
        
    else
        
        DataToAlign = in.fids(:,:,mm);
        
    end
    
    % Use first n points of time-domain data, where n is the last point where abs(diff(mean(SNR))) > 0.5
    signal = abs(DataToAlign);
    noise = 2*std(signal(ceil(0.75*size(signal,1)):end,:));
    SNR = signal ./ repmat(noise, [size(DataToAlign,1) 1]);
    SNR = abs(diff(mean(SNR,2)));
    SNR = SNR(t <= 0.2);
    tMax = find(SNR > 0.5,1,'last');
    if isempty(tMax) || tMax < find(t <= 0.1,1,'last')
        tMax = find(t <= 0.1,1,'last');
    end
    
    % Determine optimal iteration order by calculating a similarity metric (mean squared error)
    D = zeros(size(DataToAlign,2));
    for jj = 1:size(DataToAlign,2)
        for kk = 1:size(DataToAlign,2)
            tmp = sum((real(DataToAlign(1:tMax,jj)) - real(DataToAlign(1:tMax,kk))).^2) / tMax;
            if tmp == 0
                D(jj,kk) = NaN;
            else
                D(jj,kk) = tmp;
            end
        end
    end
    d = nanmedian(D);
    [~,alignOrd] = sort(d);
    
    % Turn complex-valued problem into real-valued problem
    clear flatdata
    flatdata(:,1,:) = real(DataToAlign(1:tMax,:));
    flatdata(:,2,:) = imag(DataToAlign(1:tMax,:));
    % Set initial reference transient based on similarity index
    flattarget = squeeze(flatdata(:,:,alignOrd(1)));
    target = flattarget(:);
    % Scalar to normalize transients (reduces optimization time)
    a = max(abs(target));
    
    % Pre-allocate memory
    if runCount == 0
        params = zeros(size(flatdata,3),2);
        MSE    = zeros(1,size(flatdata,3));
    end
    w = zeros(1,size(flatdata,3));
    m = zeros(length(target),size(flatdata,3));
    
    % Frame-by-frame determination of frequency of residual water and Cr (if HERMES or GSH editing)
    F0freqRange = freq - 4.68 >= -0.2 & freq - 4.68 <= 0.2;
    [~,FrameMaxPos] = max(abs(real(in.specs(F0freqRange,:))),[],1);
    F0freqRange = freq(F0freqRange);
    F0freq = F0freqRange(FrameMaxPos);
        
    % Starting values for optimization
    f0 = F0freq * in.txfrq * 1e-6;
    f0 = f0(alignOrd);
    f0 = f0 - f0(1);
    phi0 = zeros(size(f0));
    x0 = [f0(:) phi0(:)];
    
    % Determine frequency and phase offsets by spectral registration
    time = 0:input.dwelltime:(length(target)/2 - 1)*input.dwelltime;
    iter = 1;
    reverseStr = '';
    for jj = alignOrd
        
        if echo
            msg = sprintf('\nRobust spectral registration - Iteration: %d', iter);
            fprintf([reverseStr, msg]);
            reverseStr = repmat(sprintf('\b'), 1, length(msg));
        end
        
        transient = squeeze(flatdata(:,:,jj));
        input.data = transient(:)/a;
        
        fun = @(x) SpecReg(input, target/a, x);
        params(jj,:) = lsqnonlin(fun, x0(iter,:), [], [], lsqnonlinopts);
        
        f   = params(jj,1);
        phi = params(jj,2);
        m_c = complex(flatdata(:,1,jj), flatdata(:,2,jj));
        m_c = m_c .* exp(1i*pi*(time'*f*2+phi/180));
        m(:,jj) = [real(m_c); imag(m_c)];
        resid = target - m(:,jj);
        MSE(jj) = sum(resid.^2) / (length(resid) - 2);
        
%         figure(23);
%         cla;
%         hold on;
%         plot(target/a,'k','LineWidth',1);
%         plot(m(:,jj)/a,'r','LineWidth',0.5);
%         hold off;
%         ylim([-1.75 1.75]);
%         drawnow;
        
        % Update reference
        w(jj) = 0.5*corr(target, m(:,jj)).^2;
        target = (1 - w(jj))*target + w(jj)*m(:,jj);
        
        iter = iter + 1;
        
    end

    % Prepare the frequency and phase corrections to be returned by this
    % function for further use
    fs  = params(:,1);
    phs = params(:,2);
    
    % Apply frequency and phase corrections
    for jj = 1:size(flatdata,3)
        fids(:,jj,mm) = DataToAlign(:,jj) .* ...
            exp(1i*params(jj,1)*2*pi*t') * exp(1i*pi/180*params(jj,2));
    end
end

if echo
    fprintf('... done.\n');
end

%re-calculate Specs using fft
specs=fftshift(fft(fids,[],in.dims.t),in.dims.t);


%FILLING IN DATA STRUCTURE
out=in;
out.fids=fids;
out.specs=specs;

%FILLING IN THE FLAGS
out.flags=in.flags;
out.flags.writtentostruct=1;
out.flags.freqcorrected=1;




end


function out = SpecReg(input, target, x)

f   = x(1);
phi = x(2);

t = 0:input.dwelltime:(length(input.data)/2-1)*input.dwelltime;
input.data = reshape(input.data, [length(input.data)/2 2]);
fid = complex(input.data(:,1), input.data(:,2));

fid = fid .* exp(1i*pi*(t'*f*2+phi/180));
fid = [real(fid); imag(fid)];

out = target - fid;

end



%%% BELOW ARE THE SIGNAL FILTERING FUNCTIONS

function out = SignalFilter(spec, r_flag, q_flag, in)
% Based on: Cobas, J.C., Bernstein, M.A., Mart�n-Pastor, M., Tahoces, P.G.,
% 2006. A new general-purpose fully automatic baseline-correction procedure
% for 1D and 2D NMR data. J. Magn. Reson. 183, 145-51.

showPlots = 0;

[z.real, z.imag] = BaselineModeling(spec, r_flag, q_flag, in);

if showPlots == 1
    
    freq = in.ppm;
    
    H = figure(77);
    d.w = 0.5;
    d.h = 0.65;
    d.l = (1-d.w)/2;
    d.b = (1-d.h)/2;
    set(H,'Color', 'w', 'Units', 'Normalized', 'OuterPosition', [d.l d.b d.w d.h]);
    
    subplot(2,2,1); cla;
    plot(freq, real(spec), 'k');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    hold on;
    plot(freq, z.real, 'r');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    
    subplot(2,2,2); cla;
    plot(freq, imag(spec), 'k');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    hold on;
    plot(freq, z.imag, 'r');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    
    subplot(2,2,3); cla;
    plot(freq, real(spec) - z.real, 'k');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    
    subplot(2,2,4); cla;
    plot(freq, imag(spec) - z.imag, 'k');
    set(gca, 'XDir', 'reverse', 'XLim', [0 6], 'Box', 'off');
    
    drawnow;
    %pause(0.5);
    
end

out = ifft(fftshift(complex(real(spec) - z.real, imag(spec) - z.imag),[],in.dims.t),in.dims.t);

end


function [z_real, z_imag] = BaselineModeling(spec, r_flag, q_flag, in)
% Based on:
% Golotvin & Williams, 2000. Improved baseline recognition
%   and modeling of FT NMR spectra. J. Magn. Reson. 146, 122-125
% Cobas et al., 2006. A new general-purpose fully automatic
%   baseline-correction procedure for 1D and 2D NMR data. J. Magn. Reson.
%   183, 145-151

% Power spectrum of first-derivative of signal calculated by CWT
Wy = abs(cwt2(real(spec), 10)).^2;

freq = in.ppm;
noiseLim = freq <= 12 & freq >= 10;

sigma = std(Wy(noiseLim));

w = 1:5;
k = 3;
baseline = zeros(length(Wy),1);
signal = zeros(length(Wy),1);

while 1
    if w(end) > length(Wy)
        break
    end
    h = max(Wy(w)) - min(Wy(w));
    if h < k*sigma
        baseline(w) = Wy(w);
    else
        signal(w) = Wy(w);
    end
    w = w + 1;
end

% Include lipids in baseline estimate and water, as appropriate
if r_flag
    lipidLim = freq <= 1.85 & freq >= -2;
    baseline(lipidLim) = Wy(lipidLim);
end
if q_flag
    waterLim = freq <= 5.5 & freq >= 4.25;
    baseline(waterLim) = Wy(waterLim);
end

z_real = real(spec);
z_real(baseline == 0) = 0;
if r_flag
    lipids = whittaker(z_real(lipidLim), 2, 10);
end
if q_flag
    water = whittaker(z_real(waterLim), 2, 0.2);
end
z_real = whittaker(z_real, 2, 1e3);
if r_flag
    z_real(lipidLim) = lipids;
end
if q_flag
    z_real(waterLim) = water;
end

z_imag = -imag(hilbert(z_real));

end


function Wy = cwt2(y, a)

precis = 10;
coef = sqrt(2)^precis;
pas  = 1/2^precis;

lo    = [sqrt(2)*0.5 sqrt(2)*0.5];
hi    = lo .* [1 -1];
long  = length(lo);
nbpts = (long-1)/pas+2;

psi = coef*upcoef2(lo,hi,precis);
psi = [0 psi 0];
xVal = linspace(0,(nbpts-1)*pas,nbpts);

step = xVal(2) - xVal(1);
valWAV = cumsum(psi)*step;
xVal = xVal - xVal(1);
xMaxVal = xVal(end);

y = y(:)';
j = 1+floor((0:a*xMaxVal)/(a*step));
if length(j) == 1
    j = [1 1];
end
f = fliplr(valWAV(j));

Wy = -sqrt(a) * keepVec(diff(conv2(y,f,'full')),length(y));

    function out = upcoef2(lo,hi,a)
        out = hi;
        for k = 2:a
            out = conv2(dyadup2(out),lo,'full');
        end
        function out = dyadup2(in)
            z = zeros(1,length(in));
            out = [in; z];
            out(end) = [];
            out = out(:)';
        end
    end

    function out = keepVec(in,len)
        out = in;
        ok = len >= 0 && len < length(in);
        if ~ok
            return
        end
        d     = (length(in)-len)/2;
        first = 1+floor(d);
        last  = length(in)-ceil(d);
        out   = in(first:last);
    end

end

function z = whittaker(y, d, lambda)
% Code taken from: Eilers, 2003. A perfect smoother. Anal. Chem. 75,
% 3631-3636

y = y(:);

m = length(y);
E = speye(m);
D = diff(E,d);

w = double(y ~= 0);
W = spdiags(w,0,m,m);
C = chol(W + lambda*(D'*D));
z = C\(C'\(w.*y));

end
