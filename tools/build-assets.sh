#!/bin/zsh

mkdir ../build

clang -o ../build/png2c ./png2c.c

../build/png2c -n mindrot_ent -o ../build/mindrot_ent.c ../assets/mindrot_ent.png