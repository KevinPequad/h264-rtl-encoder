import numpy as np
import sys

w, h = 320, 176
try:
    orig = np.frombuffer(open('data/raw_frames.yuv', 'rb').read(w * h), dtype=np.uint8).astype(float)
    dec = np.frombuffer(open('output/decoded_frame.yuv', 'rb').read(w * h), dtype=np.uint8).astype(float)
    mse = np.mean((orig - dec) ** 2)
    psnr = 10 * np.log10(255**2 / mse) if mse > 0 else 99
    print('MSE=%.4f PSNR=%.2f dB' % (mse, psnr))
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
