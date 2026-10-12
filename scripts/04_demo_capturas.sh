#!/bin/bash
# Demo para capturas, SIN prisa: primero corre toda la prueba sola (guardando un resumen corto por fase),
# y al final muestra cada fase de una en una para que captures con calma.
# Uso (en Git Bash): bash scripts/04_demo_capturas.sh [10GB|1GB]
source "$(dirname "$0")/common.sh"
SIZE=${1:-10GB}
P=/$GRUPO/dataset_$SIZE
F=$P/dataset_${GRUPO}_${SIZE}
OUT=evidencias/demo_$SIZE; mkdir -p "$OUT"

banner() { echo "=================================================="; echo "  ${GRUPO^^} | $(date '+%Y-%m-%d %H:%M:%S') | $*"; echo "=================================================="; }
resumen_fsck()   { hdfs_nn hdfs fsck $P 2>/dev/null | grep -E "Status|Total blocks|Under-replicated|Average block replication|Missing replicas"; }
resumen_report() { hdfs_nn hdfs dfsadmin -report 2>/dev/null | grep -E "Under replicated blocks|Missing blocks:|Live datanodes|Dead datanodes|^Name:|Num of Blocks"; }
total_bloques()  { hdfs_nn hdfs fsck $P 2>/dev/null | grep -m1 "Total blocks" | grep -oE "[0-9]+" | head -1; }

# Comprobacion previa
if [ "$(live_count)" != "3" ]; then
  echo "Hay menos de 3 DataNodes vivos. Enciende el que falte (docker start g01-datanodeX) y espera 1 minuto."; exit 1
fi
until [ "$(under $P)" = "0" ]; do echo "Esperando a que no haya subreplicados..."; sleep 3; done

echo "Corriendo la prueba completa (~3-4 min). No hace falta hacer nada todavia..."

# ---------- FASE 1: ANTES ----------
hdfs_nn hdfs fsck $P -files -blocks -locations 2>/dev/null > "$OUT/_fsck_antes_raw.txt"
{ banner "FASE 1: ANTES DE LA FALLA ($SIZE)"
  docker ps --filter name=g01 --format "table {{.Names}}\t{{.Status}}"
  echo; resumen_fsck
  echo; echo "Bloques por DataNode (IP):"; blocks_per_node "$OUT/_fsck_antes_raw.txt"
  echo; echo "IP -> contenedor:"
  for c in datanode1 datanode2 datanode3; do echo "  $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' g01-$c) -> g01-$c"; done
} > "$OUT/fase1_antes.txt"

# Victima: el DataNode con mas bloques
TOPIP=$(blocks_per_node "$OUT/_fsck_antes_raw.txt" | sort -rn | head -1 | awk '{print $2}')
for c in datanode1 datanode2 datanode3; do
  [ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' g01-$c)" = "$TOPIP" ] && VICTIM=$c
done

# ---------- FASE 2: FALLA ----------
T0=$(date +%s)
docker stop g01-$VICTIM >/dev/null
TSTOP=$(date '+%H:%M:%S')
until [ "$(dead_count)" -ge 1 ] 2>/dev/null; do sleep 1; done
TDET=$(( $(date +%s)-T0 ))
{ banner "FASE 2: FALLA ($SIZE)"
  echo "\$ docker stop g01-$VICTIM      (hora: $TSTOP)  ->  g01-$VICTIM = FALLA"
  echo "NameNode declara el nodo DEAD a los $TDET s"
  echo; resumen_report
  echo; resumen_fsck
} > "$OUT/fase2_falla.txt"

# ---------- FASE 3: RECUPERACION ----------
TOTAL=$(total_bloques)
{ banner "FASE 3: RE-REPLICACION ($SIZE)"
  while true; do
    U=$(under $P); U=${U:-0}
    echo "[$(date +%T)] ${GRUPO^^} $SIZE | bloques subreplicados = $U de $TOTAL"
    [ "$U" -eq 0 ] && break
    sleep 3
  done
  echo "Recuperado: $(( $(date +%s)-T0 )) s desde que se detuvo el nodo"
} > "$OUT/fase3_recuperacion.txt"

# ---------- FASE 4: FINAL ----------
hdfs_nn hdfs fsck $P -files -blocks -locations 2>/dev/null > "$OUT/_fsck_despues_raw.txt"
MD5N=$(hdfs_nn bash -c "hdfs dfs -cat $F 2>/dev/null | md5sum" | awk '{print $1}')
MD5O=$(awk '{print $1}' resultados/$SIZE/md5_original.txt 2>/dev/null)
{ banner "FASE 4: DESPUES DE LA RECUPERACION ($SIZE)"
  resumen_fsck
  echo; echo "Bloques por DataNode (IP):"; blocks_per_node "$OUT/_fsck_despues_raw.txt"
  echo; resumen_report
  echo; echo "Integridad (md5 del archivo leido con el nodo caido): $MD5N"
  [ -n "$MD5O" ] && { [ "$MD5N" = "$MD5O" ] && echo "  = md5 original -> DATOS INTACTOS" || echo "  != md5 original"; }
} > "$OUT/fase4_final.txt"

# ---------- VISOR: captura con calma ----------
nombres=(01_antes 02_falla 03_recuperacion 04_final)
archivos=(fase1_antes fase2_falla fase3_recuperacion fase4_final)
for i in 0 1 2 3; do
  printf '\033c'
  cat "$OUT/${archivos[$i]}.txt"
  echo
  echo ">>> CAPTURA $((i+1)) de 5:  Win+Shift+S  y guardala como  evidencias/${nombres[$i]}.png"
  read -r -p ">>> Cuando la tengas, pulsa Enter... " _
done
printf '\033c'
echo "CAPTURA 5 de 5 (navegador):"
echo "  1) Abre http://localhost:9870  ->  pestana 'Datanodes'  ->  F5"
echo "  2) Debe verse g01-$VICTIM caido. Captura y guardala como evidencias/05_ui_datanodes_muerto.png"
read -r -p ">>> Cuando la tengas, pulsa Enter para RESTAURAR g01-$VICTIM... " _
docker start g01-$VICTIM >/dev/null
echo "g01-$VICTIM reiniciado. Listo."
