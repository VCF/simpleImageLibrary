#!/bin/bash

## Random bash snippets


## An image file path:
imPath="be5.jpg"

## Get the fingerprint of an image
FP="$(findimagedupes -v fp "$imPath")"

## Fingerprint is binhex
## Convert binhex to single hex string:
hdFP="$(echo "$FP" | base64 -d | xxd -p -c 100)"

## Find all images that are "95% similar" in a directory
findimagedupes -t 95% some/dir

## Imagemagic compare
## I didn't find this terribly useful

compare -verbose -metric rmse 5ba.jpeg 307.jpg diffMask.png
