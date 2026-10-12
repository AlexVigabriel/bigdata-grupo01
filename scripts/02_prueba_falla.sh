#!/bin/bash
# Prueba de fallo: ./02_prueba_falla.sh 1GB datanode2
source "$(dirname "$0")/common.sh"
SIZE=$1; VICTIM=$2
P=/$GRUPO/dataset_$SIZE
FN=dataset_${GRUPO}_${SIZE}
F=$P/$FN
OUT=resultados/${SIZE}; mkdir -p "$OUT"
LOG=$OUT/linea_de_tiempo.txt; : > $LOG
MON=$OUT/monitor.csv
log() { echo "[$(ts)] $*" | tee -a $LOG; }
jmx() { curl -s "http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem" | tr -d ' ,' | grep -E "\"$1\"" | cut -d: -f2; }
ms() { echo $(( $(date +%s%N) / 1000000 )); }
# Una sola consulta JMX por muestra: vivos,muertos,subreplicados,pendientes,perdidos
jmxall() { curl -s "http://localhost:9870/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem" | tr -d ' ,' | awk -F: '/"NumLiveDataNodes"/{l=$2}/"NumDeadDataNodes"/{d=$2}/"UnderReplicatedBlocks"/{u=$2}/"PendingReplicationBlocks"/{p=$2}/"MissingBlocks"/{m=$2}END{print l","d","u","p","m}'; }

# Estado inicial limpio: 3 nodos vivos y 0 subreplicados
until [ "$(jmx NumLiveDataNodes)" = "3" ] && [ "$(jmx UnderReplicatedBlocks)" = "0" ] && [ "$(jmx PendingReplicationBlocks)" = "0" ]; do sleep 2; done
log "=== ANTES DE LA FALLA ($GRUPO, $SIZE) ==="
hdfs_nn hdfs dfsadmin -report > $OUT/1_antes_report.txt
hdfs_nn hdfs fsck $P -files -blocks -locations > $OUT/1_antes_fsck.txt
log "DN1/DN2/DN3 -> Activos: $(jmx NumLiveDataNodes) vivos"
log "Bloques por DataNode (IP) ANTES:"; blocks_per_node $OUT/1_antes_fsck.txt | tee -a $LOG
grep -E "Total blocks|Average block replication|Under-replicated|Status" $OUT/1_antes_fsck.txt | tee -a $LOG
# VICTIM=auto -> el DataNode con mas bloques (tras restaurar, un nodo puede quedar vacio)
if [ "$VICTIM" = "auto" ]; then
  TOPIP=$(blocks_per_node $OUT/1_antes_fsck.txt | sort -rn | head -1 | awk '{print $2}')
  for c in datanode1 datanode2 datanode3; do
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' g01-$c)
    [ "$IP" = "$TOPIP" ] && VICTIM=$c
  done
  log "Victima elegida automaticamente: $VICTIM ($TOPIP, el nodo con mas bloques)"
fi
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Monitor en segundo plano (cada 0.5 s) via JMX del NameNode
echo "ms,hora,vivos,muertos,subreplicados,pendientes,perdidos" > $MON
( while true; do
    echo "$(ms),$(ts),$(jmxall)" >> $MON
    sleep 0.1
  done ) &
MONPID=$!
sleep 3

T0=$(ms)
log "=== DETENIENDO $VICTIM (g01-$VICTIM) ==="
docker stop g01-$VICTIM >/dev/null
log "$VICTIM -> FALLA"

# Lectura inmediata en segundo plano: -get a archivo local, con tiempo, tamano y md5
( hdfs_nn bash -c "rm -f /tmp/lectura_$FN; S=\$(date +%s); hdfs dfs -get $F /tmp/lectura_$FN > /tmp/get_out.txt 2>&1; echo exit=\$? tiempo=\$((\$(date +%s)-S))s; ls -l /tmp/lectura_$FN | awk '{print \"bytes=\"\$5}'; md5sum /tmp/lectura_$FN; rm -f /tmp/lectura_$FN" > $OUT/lectura_durante.txt ) &
READPID=$!

# Esperar a que el NN declare el nodo muerto
until [ "$(jmx NumDeadDataNodes)" -ge 1 ] 2>/dev/null; do sleep 0.3; done
TD=$(ms)
log "Nodo declarado DEAD: +$(( (TD-T0)/1000 )) s tras detenerlo"
hdfs_nn hdfs dfsadmin -report > $OUT/2_durante_report.txt

# Evolucion de la re-replicacion vista por fsck (hasta 0 subreplicados)
echo "ms,hora,subreplicados,bloques_total" > $OUT/fsck_evolucion.csv
TU=""; TR=""; MAXU=0; GUARDADO=0
while true; do
  hdfs_nn hdfs fsck $P -files -blocks -locations > /tmp/g05_fsck_iter.txt 2>/dev/null || true
  NOW=$(ms)
  U=$(grep -m1 "Under-replicated blocks" /tmp/g05_fsck_iter.txt | grep -oE ":[[:space:]]*[0-9]+" | grep -oE "[0-9]+"); U=${U:-0}
  echo "$NOW,$(ts),$U,$(grep -m1 'Total blocks' /tmp/g05_fsck_iter.txt | grep -oE '[0-9]+' | head -1)" >> $OUT/fsck_evolucion.csv
  if [ "$U" -gt 0 ]; then
    [ -z "$TU" ] && TU=$NOW
    [ "$U" -gt "$MAXU" ] && MAXU=$U
    cp /tmp/g05_fsck_iter.txt $OUT/2_durante_fsck_subreplicado.txt; GUARDADO=1
  fi
  if [ "$U" -eq 0 ] && { [ -n "$TU" ] || [ $(( NOW-TD )) -gt 40000 ]; }; then TR=$NOW; break; fi
done
sleep 2; kill $MONPID 2>/dev/null; wait $MONPID 2>/dev/null
cp /tmp/g05_fsck_iter.txt $OUT/2_durante_fsck.txt
wait $READPID
hdfs_nn cat /tmp/get_out.txt > $OUT/lectura_durante_logcliente.txt
log "Lectura iniciada justo al detener el nodo:"; cat $OUT/lectura_durante.txt | tee -a $LOG

# Tiempos
MAXP=$(awk -F, 'NR>1 && $6>m {m=$6} END{print m+0}' $MON)
if [ -n "$TU" ]; then
  log "fsck vio $MAXU bloque(s) subreplicado(s) (JMX pendientes max=$MAXP): +$(( (TU-T0)/1000 )) s; recuperado a 0: +$(( (TR-T0)/1000 )) s (re-replicacion: $((TR-TU)) ms desde primer fsck subreplicado)"
else
  log "fsck no alcanzo a ver subreplicados (JMX pendientes max=$MAXP); revisar logs de DataNodes"
fi
echo "deteccion_s=$(( (TD-T0)/1000 )) subrepl_visto_s=$(( ${TU:-0}>0 ? (TU-T0)/1000 : -1 )) recuperado_s=$(( (TR-T0)/1000 )) recuperacion_desde_deteccion_s=$(( (TR-TD)/1000 )) max_subreplicados_fsck=$MAXU max_pendientes_jmx=$MAXP" > $OUT/tiempos.txt

log "=== DURANTE (nodo ya muerto) ==="
grep -E "Dead datanodes|Live datanodes" $OUT/2_durante_report.txt | tee -a $LOG
log "=== DESPUES DE LA RECUPERACION ==="
hdfs_nn hdfs dfsadmin -report > $OUT/3_despues_report.txt
hdfs_nn hdfs fsck $P -files -blocks -locations > $OUT/3_despues_fsck.txt
log "Bloques por DataNode (IP) DESPUES:"; blocks_per_node $OUT/3_despues_fsck.txt | tee -a $LOG
grep -E "Under-replicated|Missing replicas|Status|Average block replication" $OUT/3_despues_fsck.txt | tee -a $LOG
hdfs_nn bash -c "hdfs dfs -cat $F 2>/dev/null | md5sum" > $OUT/md5_despues.txt
log "md5 original: $(cat $OUT/md5_original.txt)"; log "md5 despues : $(cat $OUT/md5_despues.txt)"

# Evidencia de logs: quien copio que, y hacia donde
docker logs --since "$SINCE" g01-namenode 2>&1 | grep -E "removeDeadDatanode|Removing a node|replicate|BlockStateChange" | cut -c1-250 > $OUT/log_namenode.txt
for d in datanode1 datanode2 datanode3; do docker logs --since "$SINCE" g01-$d 2>&1 | grep -E "Transmitted|DataTransfer|Receiving|Received" | cut -c1-250 > $OUT/log_$d.txt; done
log "Transferencias entre DataNodes (nuevas replicas):"
grep -h "Transmitted block\|DataTransfer" $OUT/log_datanode*.txt | tee -a $LOG | head -20

log "=== RESTAURANDO $VICTIM ==="
docker start g01-$VICTIM >/dev/null
until [ "$(jmx NumLiveDataNodes)" = "3" ]; do sleep 2; done
sleep 30
hdfs_nn hdfs fsck $P | grep -E "Over-replicated|Under-replicated|Status" | tee -a $LOG
hdfs_nn hdfs fsck $P -files -blocks -locations > $OUT/4_restaurado_fsck.txt
log "Bloques por DataNode (IP) tras restaurar:"; blocks_per_node $OUT/4_restaurado_fsck.txt | tee -a $LOG
