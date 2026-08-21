#!/bin/sh

echo "-------------------------------------------"
echo ""
echo "###########################################"
echo "[INFO] 1. Build Executables"
echo "###########################################"

cd $HAMMER_ROOT/src
rm -rf out
cmake -S . -B out/build
cd out/build && make -j 
cd $BREACH_ROOT

cd src/
rm -rf out
cmake -S . -B out
cd out && make -j
cd $BREACH_ROOT

cd cred_mod/
make
sudo rmmod get_cred_addr.ko
sudo insmod get_cred_addr.ko
cd $BREACH_ROOT
