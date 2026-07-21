# Golden-master: validar que el MOTOR de MT5 y MT4 responde igual

Verifica que la homologación del guardián (2026-07-21) NO movió el motor Oracle, y
que MT5 y MT4 producen el mismo grid. El guardián NO se testea aquí (el Strategy
Tester no soporta WebRequest/DLL/toggle) — eso va por revisión de código.

## Qué prueba
El comparador (`golden_master_compare.py`) parsea el reporte HTML del Strategy Tester
de cada plataforma y compara, en términos NORMALIZADOS (no precios absolutos):
- número de trades (±5%),
- ratio buy/sell (±10%),
- **spacing del grid entre niveles** — lo que el motor controla; debe coincidir.

## Procedimiento (requiere la GUI del tester — 15 min)

Los inputs deben ser IDÉNTICOS en ambos: `Oracle_TakeProfit=15, Oracle_GridSize=30,
Oracle_FixedLot=0.01, Oracle_GridFactor=1.0, Oracle_EngineA=true, Oracle_EngineB=true,
CloseOnVolSpike=false, Oracle_BasketStopUSD=0`. El guardián de noticias no dispara en
el tester (sin feed), así que no contamina.

### MT5
1. Abrir el Strategy Tester (Ctrl+R), Expert = `Cerberus`, símbolo `XAUUSDm`, timeframe M1.
2. Modelo: "Every tick based on real ticks" (o "OHLC 1 min" si no hay ticks reales).
3. Periodo: elegir un rango con movimiento (p.ej. una semana reciente de XAUUSDm).
4. Cargar los inputs de arriba. Ejecutar.
5. Pestaña de resultados → clic derecho → "Report" → guardar como `mt5_report.htm`.

### MT4
1. Strategy Tester (Ctrl+R), Expert = `Cerberus`, símbolo `XAUUSDm`, M1.
2. Modelo: "Every tick" (el más preciso que tenga el MT4).
3. MISMO periodo que MT5.
4. MISMOS inputs. Ejecutar.
5. Pestaña "Results" → clic derecho → "Save as Report" → `mt4_report.htm`.

### Comparar
```
python tools/golden_master_compare.py mt5_report.htm mt4_report.htm --label-a MT5 --label-b MT4
```
Exit 0 = motores coinciden. Exit 1 = divergencia (investigar antes de confiar en la
comparación entre plataformas).

## Regresión (recomendado antes/después de la homologación)
Como el tester no corre el guardián, la homologación NO debería mover el motor.
Para confirmarlo: correr el MT4 en el tester ANTES de la homologación (guardar
`mt4_before.htm`) y DESPUÉS (`mt4_after.htm`), y:
```
python tools/golden_master_compare.py mt4_before.htm mt4_after.htm --label-a before --label-b after
```
Deben coincidir exactamente (mismo motor). Si difieren, algún cambio tocó el motor
por error — revisar.

## Límite conocido
Los modelos de tick de MT4 y MT5 no son idénticos (MT5 tiene ticks reales, MT4
modela). Por eso el comparador usa TOLERANCIAS (spacing ±2 pips, conteo ±5%) en
lugar de igualdad exacta: valida que el motor se comporta EQUIVALENTE, no que
genera el byte-idéntico trade log (imposible con modelos de tick distintos).
