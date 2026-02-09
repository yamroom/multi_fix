#!/bin/bash

A=0.7
B=1.23
C=3.56

A_x=0
B_x=0
C_x=0

echo "A=$(awk -v a="$A" -v b="$A_x" 'BEGIN {print a + b}')"
echo "B=$(awk -v a="$B" -v b="$B_x" 'BEGIN {print a + b}')"
echo "C=$(awk -v a="$C" -v b="$C_x" 'BEGIN {print a + b}')"
