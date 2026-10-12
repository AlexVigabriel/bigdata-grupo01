#!/bin/bash
# Funciones comunes. Cambia GRUPO si tu grupo es otro.
export MSYS_NO_PATHCONV=1
GRUPO=grupo01
NN=g01-namenode
hdfs_nn() { docker exec "$NN" "$@"; }
ts() { date +%T; }
fsck_summary() { hdfs_nn hdfs fsck "$1" 2>/dev/null; }
under() { fsck_summary "$1" | grep -m1 "Under-replicated blocks" | grep -oE ":[[:space:]]*[0-9]+" | grep -oE "[0-9]+"; }
live_count() { hdfs_nn hdfs dfsadmin -report 2>/dev/null | awk '/^Live datanodes/{gsub(/[^0-9]/,"",$3); print $3; exit}'; }
dead_count() { local d; d=$(hdfs_nn hdfs dfsadmin -report 2>/dev/null | awk '/^Dead datanodes/{gsub(/[^0-9]/,"",$3); print $3; exit}'); echo "${d:-0}"; }
# bloques por DataNode (IP) a partir de un fsck -locations
blocks_per_node() { grep -oE 'DatanodeInfoWithStorage\[[0-9.]+' "$1" | sed 's/.*\[//' | sort | uniq -c; }
