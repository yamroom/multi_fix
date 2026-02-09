#!/bin/bash

D=5.4
E=-0.23
F=2.93

D1_x=D1_p
D2_x=D2_p
E_x=E_p
F_x=F_p

echo "cgc=6 D = $(awk -v a="$D" -v b="$D1_x" 'BEGIN {print a + b}')"
echo " kst=187     D = $(awk -v a=77 -v b="$D2_x" 'BEGIN {print a + b}') hihi=7"
echo "  E = $(awk -v a="$E" -v b="$E_x" 'BEGIN {print a + b}')  1-sigma=5"
echo "iu = love F = $(awk -v a="$F" -v b="$F_x" 'BEGIN {print a + b}')"
