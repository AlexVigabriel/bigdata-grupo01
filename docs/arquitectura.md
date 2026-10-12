# Diagrama de arquitectura - Grupo 01

```mermaid
flowchart TB
    subgraph host["Host Windows 11 + Docker Desktop (red bigdata-grupo01_default)"]
        direction TB
        CLI["Cliente HDFS<br/>(docker exec en g01-namenode)<br/>put / get / fsck / dfsadmin"]
        NN["<b>NameNode</b><br/>g01-namenode<br/>RPC :8020 | Web UI :9870<br/>Metadatos: arbol de directorios,<br/>mapa bloque -> DataNodes"]
        DN1["<b>DataNode 1</b><br/>g01-datanode1"]
        DN2["<b>DataNode 2</b><br/>g01-datanode2"]
        DN3["<b>DataNode 3</b><br/>g01-datanode3"]
    end
    CLI -- "1. metadatos (donde escribo / leo)" --> NN
    CLI -. "2. datos (bloques de 128 MB)" .-> DN1
    DN1 -- "3. pipeline de replicacion" --> DN2
    DN2 -- "pipeline" --> DN3
    DN1 -- "heartbeat cada 3 s + block report" --> NN
    DN2 -- "heartbeat + block report" --> NN
    DN3 -- "heartbeat + block report" --> NN
    NN -- "ordenes: replicar / borrar bloque" --> DN3
```

## Parametros relevantes (config.env)

| Parametro | Valor | Motivo |
|---|---|---|
| `dfs.replication` | 2 | Requisito de la practica (>= 2) |
| `dfs.blocksize` | 134217728 (128 MB) | 1 GB = 8 bloques, 10 GB = 80 bloques |
| `dfs.heartbeat.interval` | 3 s | Valor por defecto |
| `dfs.namenode.heartbeat.recheck-interval` | 10000 ms | Baja el tiempo de deteccion de nodo muerto de ~10,5 min a ~50 s: `2 x recheck + 10 x heartbeat` |

## Rutas en HDFS

```
/grupo01/dataset_1GB/dataset_grupo01_1GB
/grupo01/dataset_10GB/dataset_grupo01_10GB
/grupo01/resultados/
/grupo01/evidencias/
```
