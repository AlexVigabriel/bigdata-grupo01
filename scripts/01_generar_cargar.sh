#!/bin/bash
# Genera datasets aleatorios dentro del NameNode y los carga a HDFS con tiempos.
source "$(dirname "$0")/common.sh"
SIZE=$1   # 1GB | 10GB
OUT=resultados/${SIZE}; mkdir -p "$OUT"
FILE=dataset_${GRUPO}_${SIZE}
GB=${SIZE%GB}
hdfs_nn bash -c "[ -f /tmp/$FILE ] || head -c ${GB}G /dev/urandom > /tmp/$FILE"
hdfs_nn md5sum /tmp/$FILE | tee $OUT/md5_original.txt
hdfs_nn hdfs dfs -mkdir -p /$GRUPO/dataset_$SIZE /$GRUPO/resultados /$GRUPO/evidencias
S=$(date +%s)
hdfs_nn hdfs dfs -put -f /tmp/$FILE /$GRUPO/dataset_$SIZE/
E=$(date +%s)
echo "Tiempo de carga ${SIZE}: $((E-S)) s" | tee $OUT/tiempo_carga.txt
hdfs_nn hdfs dfs -ls -h /$GRUPO/dataset_$SIZE | tee $OUT/ls.txt
