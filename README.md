# bigdata-grupo01 - Tolerancia a fallos y replicación de datos en HDFS (LG15)

Universidad del Valle. Clúster Hadoop HDFS con **1 NameNode + 3 DataNodes**, factor de replicación **2**, y pruebas de caída de un DataNode con datasets de **1 GB** y **10 GB**. **Grupo 01.**

## Arquitectura
Ver [docs/arquitectura.md](docs/arquitectura.md) (diagrama Mermaid y parámetros).

## Estructura
```
docker-compose.yml        Clúster (1 NN + 3 DN, imagen apache/hadoop:3.3.6, contenedores g01-*)
config.env                Configuración HDFS (replicación=2, bloque=128 MB, ...)
scripts/common.sh         Funciones auxiliares (GRUPO=grupo01)
scripts/01_generar_cargar.sh   Genera el dataset aleatorio y lo carga a HDFS (con tiempos)
scripts/02_prueba_falla.sh     Prueba de fallo completa (antes / durante / después / restauración)
scripts/03_evidencias_guiado.sh  Demo guiada con pausas para tomar capturas (guarda la salida en evidencias/texto_*)
resultados/               Salidas de cada experimento (ver abajo)
evidencias/               Capturas de pantalla (UI web del NameNode)
docs/arquitectura.md      Diagrama
```
Rutas en HDFS: `/grupo01/dataset_1GB/dataset_grupo01_1GB`, `/grupo01/dataset_10GB/dataset_grupo01_10GB`, `/grupo01/resultados`, `/grupo01/evidencias`.

Archivos clave dentro de `resultados/1GB` y `resultados/10GB`: `1_antes_fsck.txt` / `1_antes_report.txt` (estado inicial y ubicación de réplicas), `2_durante_report.txt` / `2_durante_fsck*.txt` (nodo muerto, subreplicados), `3_despues_fsck.txt` / `3_despues_report.txt`, `linea_de_tiempo.txt`, `monitor.csv` (JMX cada ~0,25 s), `fsck_evolucion.csv`, `lectura_durante.txt` (lectura con el nodo caído), `log_namenode.txt` y `log_datanode*.txt` (transferencias de nuevas réplicas), `md5_*.txt` (integridad).

## Instalación y ejecución
Requisitos: Docker Desktop, bash (Git Bash/WSL), `curl`, ~40 GB libres.

```bash
docker compose up -d                              # levanta NN + 3 DN
docker exec g01-namenode hdfs dfsadmin -report    # verificar "Live datanodes (3)"

bash scripts/01_generar_cargar.sh 1GB
bash scripts/02_prueba_falla.sh 1GB auto          # 'auto' = detiene el DataNode con más bloques

bash scripts/01_generar_cargar.sh 10GB
bash scripts/02_prueba_falla.sh 10GB auto
```
UI web del NameNode: http://localhost:9870

El script de fallo registra el estado inicial, detiene un DataNode, intenta leer el archivo, espera la detección del nodo muerto, sigue la evolución hasta 0 subreplicados, verifica integridad con md5, guarda los logs de NameNode/DataNodes y restaura el nodo.

**Decisión de configuración:** `dfs.namenode.heartbeat.recheck-interval=10000` reduce la detección de nodo muerto de ~10,5 min a ~50 s (`2 x recheck + 10 x heartbeat`), para que el experimento sea viable. Es la única desviación relevante de los valores por defecto.

## Resultados

Cargas: 1 GB en 5 s, 10 GB en 24 s. Mapa IP -> nodo: datanode1 = 172.21.0.4, datanode2 = 172.21.0.5, datanode3 = 172.21.0.3.

### Prueba 1 - dataset 1 GB (`resultados/1GB/`)
| Fase | Observación |
|---|---|
| Antes | 8 bloques x 2 réplicas, `HEALTHY`. Réplicas por nodo: DN1 = 5, DN2 = 7, DN3 = 4. |
| Falla | Se detiene **datanode2** (7 de los 8 bloques). |
| Detección | El NameNode lo declara muerto a los **53 s** (`Live datanodes (2)`, `Dead datanodes (1)`). |
| Lectura | Archivo accesible: `hdfs dfs -get` con `exit=0`, 1 073 741 824 bytes, md5 idéntico al original. Tardó 42 s porque el cliente prueba primero la réplica del nodo caído. |
| Subreplicados | Sí: el NameNode reportó **4 bloques pendientes de replicación** (JMX `PendingReplicationBlocks`) justo al detectar el nodo muerto, sin bloques `MISSING`. El muestreo de `fsck` (cada ~2 s) no llegó a verlos porque la re-replicación duró ~10 s. |
| Recuperación | 7 transferencias: 4 de datanode1 -> datanode3 y 3 de datanode3 -> datanode1 (de a pocos bloques por ciclo). Recuperado ~**62 s** tras la caída (**~10 s** desde la detección). |
| Después | 8 bloques en DN1 y 8 en DN3, `HEALTHY`, replicación promedio 2.0, md5 íntegro. |

### Prueba 2 - dataset 10 GB (`resultados/10GB/`)
| Fase | Observación |
|---|---|
| Antes | 80 bloques x 2 réplicas, `HEALTHY`. DN1 = 46, DN2 = 54, DN3 = 60 bloques. |
| Falla | Se detiene **datanode3** (60 bloques, el 75 % del archivo). |
| Detección | Muerto a los **52 s**. |
| Lectura | Archivo accesible: `exit=0`, 10 737 418 240 bytes, md5 idéntico. Tardó 76 s. |
| Subreplicados | Sí: `fsck` vio **60** bloques subreplicados en la primera consulta (+56 s), sin `MISSING`. |
| Recuperación | Descenso gradual de 60 a 0 durante ~65-70 s. Recuperado a los **125 s** desde la caída (**~72 s** desde la detección). |
| Nuevas réplicas | datanode2 -> datanode1: 34 bloques; datanode1 -> datanode2: 34 bloques. Son 68 porque el clúster también re-replicó **8 bloques del dataset de 1 GB** que estaban en ese nodo (60 + 8). |
| Después | 80 bloques en DN1 y 80 en DN2 (DN3 muerto), `HEALTHY`, md5 íntegro. |

### Comparación
| Característica | Dataset 1 GB | Dataset 10 GB |
|---|---|---|
| Tamaño | 1 GB | 10 GB |
| Número de bloques | 8 | 80 |
| Factor de replicación | 2 | 2 |
| DataNode afectado | datanode2 | datanode3 |
| Bloques afectados | 7 (87,5 %) | 60 (75 %) |
| Bloques disponibles tras la falla | 8 de 8 (1 réplica viva c/u) | 80 de 80 |
| ¿Archivo accesible? | Sí (md5 íntegro) | Sí (md5 íntegro) |
| ¿Bloques subreplicados? | Sí (4 pendientes vistos por JMX) | Sí (60 vistos por fsck) |
| Tiempo de recuperación | ~62 s desde la caída / ~10 s desde la detección | 125 s desde la caída / ~72 s desde la detección |
| Nuevas réplicas | 7 (4 en datanode3, 3 en datanode1) | 60 del dataset (+8 del de 1 GB), repartidas entre datanode1 y datanode2 |

La detección (~53 s) es constante porque depende de heartbeats; el tiempo de re-replicación crece con la cantidad de bloques afectados (el NameNode limita cuántos programa por ciclo).

## Análisis

**Antes.** 1 GB = 8 bloques de 128 MB; 10 GB = 80 bloques. Todos con 2 réplicas, repartidas entre los DataNodes (ver `1_antes_fsck.txt`).

**Durante.** Al detener un DataNode, el NameNode no lo sabe de inmediato: espera la ausencia de heartbeats (~53 s). Mientras tanto la lectura sigue funcionando porque cada bloque tenía otra réplica, pero con más latencia (el cliente primero intenta el nodo caído). Al declararlo muerto, el NameNode marca como subreplicados los bloques que estaban en él (quedan con 1 de 2 réplicas) y los encola.

**Después.** El NameNode ordena a un DataNode que conserva una réplica que la copie a otro nodo vivo que no tenga ese bloque, por tandas. Al terminar: 0 subreplicados, factor 2 restablecido sobre los 2 nodos restantes. Al reiniciar el nodo caído, sus réplicas antiguas quedan sobrerreplicadas y el NameNode borra las sobrantes (por eso el nodo restaurado queda vacío y la distribución desbalanceada).

## Preguntas de exposición
1. **¿Por qué sigue disponible?** Cada bloque tiene otra réplica en un nodo vivo; el cliente obtiene del NameNode las ubicaciones y lee de cualquiera.
2. **¿Con factor 1?** Los bloques del nodo caído quedarían `MISSING`; el archivo sería ilegible hasta recuperar el nodo (y se perdería si el disco fallara).
3. **¿Fallan dos nodos a la vez?** Con 3 nodos y factor 2, los bloques cuyas dos réplicas estaban justo en esos dos nodos se pierden: el archivo queda incompleto/corrupto.
4. **¿Por qué factor 2 no implica dos copias completas?** La replicación es por bloque, no por archivo: cada bloque se coloca en un par de nodos distinto (en 10 GB, DN1/DN2/DN3 tenían 46/54/60 bloques; ninguno tenía el archivo completo).
5. **Tamaño de bloque vs. número de bloques:** inversamente proporcionales, `bloques = ceil(tamaño / tamaño_bloque)`. Con 128 MB: 8 y 80.
6. **¿Por qué 10 GB es más representativo?** 80 bloques se reparten de forma más variada entre nodos, y la re-replicación dura lo suficiente (~65-70 s) para observar el descenso gradual de subreplicados; con 8 bloques todo ocurre en ~10 s.
7. **Bloques con réplica en el nodo caído:** quedan subreplicados (1 de 2), el NameNode los programa y un DataNode con réplica viva los copia a otro nodo.
8. **¿Quién administra ubicación y replicación?** El **NameNode** (metadatos, detección de nodos muertos, órdenes de replicar/borrar). Los DataNodes almacenan y reportan; el cliente solo consulta.
9. **Disponibilidad vs. factor de replicación:** el archivo puede estar disponible (>=1 réplica por bloque) mientras el factor deseado no se cumple (subreplicados). Esa ventana es de riesgo: otra falla podría causar pérdida.

## Notas de la metodología
- Si se tumba un nodo que quedó **vacío** tras una restauración, no ocurre re-replicación; por eso `02_prueba_falla.sh` acepta `auto` y elige el DataNode con más bloques.
- La lectura se verifica con `hdfs dfs -get` + tamaño + md5 (las trazas del cliente Hadoop se mezclan con stdout y alteran el md5 si se usa `-cat | md5sum`).
- Los bloques en re-replicación pueden pasar de "subreplicados" a "pendientes" casi al instante; por eso se monitorean ambas métricas (JMX del NameNode) además de `fsck`.
