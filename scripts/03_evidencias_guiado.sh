#!/bin/bash
# Demo guiada para tomar capturas de pantalla. Uso: bash scripts/03_evidencias_guiado.sh [1GB|10GB]
# En cada pausa: toma la captura (Win+Shift+S) del navegador en http://localhost:9870 y pulsa Enter.
source "$(dirname "$0")/common.sh"
SIZE=${1:-10GB}
P=/$GRUPO/dataset_$SIZE
F=$P/dataset_${GRUPO}_${SIZE}
OUT=evidencias/texto_$SIZE; mkdir -p "$OUT"
n=0
banner() { echo; echo "=================================================="; echo "  ${GRUPO^^} | $(date '+%Y-%m-%d %H:%M:%S') | $*"; echo "=================================================="; }
# ejecuta un comando, lo muestra con el banner y lo guarda en un archivo numerado
paso() { n=$((n+1)); local nombre=$1; shift; local f=$(printf "%s/%02d_%s.txt" "$OUT" $n "$nombre")
  { banner "$nombre"; echo "\$ $*"; "$@" 2>&1; } | grep -v "^Connecting" | tee "$f"; }
pausa() { echo; echo ">>> CAPTURA: $*"; read -r -p ">>> Cuando la tengas, pulsa Enter... " _; }

paso contenedores_activos docker ps --filter name=g01 --format "table {{.Names}}\t{{.Status}}"
pausa "UI -> pestana Datanodes (3 nodos In Service) y Utilities > Browse the file system > $P"

paso estado_inicial_report hdfs_nn hdfs dfsadmin -report
paso estado_inicial_fsck hdfs_nn hdfs fsck $P -files -blocks -locations
hdfs_nn hdfs fsck $P -files -blocks -locations 2>/dev/null > "$OUT/_antes_fsck_raw.txt"
echo; echo "Bloques por DataNode (IP) ANTES:"; blocks_per_node "$OUT/_antes_fsck_raw.txt"
TOPIP=$(blocks_per_node "$OUT/_antes_fsck_raw.txt" | sort -rn | head -1 | awk '{print $2}')
for c in datanode1 datanode2 datanode3; do
  [ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' g01-$c)" = "$TOPIP" ] && VICTIM=$c
done
pausa "terminal: fsck con /grupo01/..., bloques, Live_repl=2 y el reparto por DataNode"

echo; echo "Se detendra: $VICTIM (el DataNode con mas bloques)"
read -r -p ">>> Pulsa Enter para DETENER $VICTIM... " _
T0=$(date +%s)
paso detener_datanode docker stop g01-$VICTIM
pausa "terminal: el comando 'docker stop g01-$VICTIM' (estado: FALLA)"

echo; echo "Esperando a que el NameNode declare muerto al nodo (~50 s)..."
until [ "$(dead_count)" -ge 1 ] 2>/dev/null; do printf "\r  transcurrido: %ss " $(( $(date +%s)-T0 )); sleep 2; done
echo; echo "NameNode: $VICTIM DEAD a los $(( $(date +%s)-T0 )) s"
paso nodo_muerto_report hdfs_nn hdfs dfsadmin -report
pausa "UI -> pestana Datanodes (nodo Dead/Down) y Overview"

# Evolucion de subreplicados hasta 0
echo; echo "Siguiendo la re-replicacion (fsck cada ~3 s). Captura la terminal mientras 'Under-replicated' > 0."
paso subreplicados_inicial hdfs_nn hdfs fsck $P -files -blocks -locations
while true; do
  U=$(under $P); U=${U:-0}
  echo "[$(date +%T)] ${GRUPO} $SIZE subreplicados=$U" | tee -a "$OUT/evolucion_subreplicados.txt"
  [ "$U" -eq 0 ] && break
  sleep 3
done
pausa "terminal: la evolucion de subreplicados bajando hasta 0 (y la UI Overview)"

paso lectura_con_nodo_caido bash -c "docker exec g01-namenode bash -c 'hdfs dfs -get $F /tmp/demo_lectura && ls -l /tmp/demo_lectura && md5sum /tmp/demo_lectura; rm -f /tmp/demo_lectura'"
paso recuperado_fsck hdfs_nn hdfs fsck $P -files -blocks -locations
paso recuperado_report hdfs_nn hdfs dfsadmin -report
pausa "terminal: HEALTHY, Under-replicated blocks: 0, nuevas replicas en los nodos vivos; UI -> Datanodes"

read -r -p ">>> Pulsa Enter para RESTAURAR $VICTIM... " _
paso restaurar_datanode docker start g01-$VICTIM
echo; echo "Listo. Salidas de texto en $OUT/. Guarda tus capturas en evidencias/."
