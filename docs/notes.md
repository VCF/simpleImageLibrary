
## Fingerprinting

Calculate fingerprint, trim to just fingerprint, convert b64 to hexadecimal

```bash
findimagedupes \
  --no-compare \
  --verbosity=fingerprint \
  /home/tilfordc/ToFile/Puppy.jpg |\
  cut -d' ' -f1 - |\
  base64 --decode |\
  xxd -p -c 256
```

Will need to find decent default thresholds
* Base default is `--threshold=90%`
* Image templates (memes) may have much more similarity than most images