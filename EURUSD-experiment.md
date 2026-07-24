# Cerberus en EURUSD — rama de experimento (DEMO)

Rama `eurusd-experiment`. Config: [config/Cerberus_EURUSD.set](config/Cerberus_EURUSD.set).

> **Solo demo.** Cerberus NO está validado (va perdiendo en vivo en oro). Esto rompe la
> regla del proyecto si toca dinero real. Se prueba en demo, se mide net USD por semanas,
> y solo después se decide. **No es el "plan sano de $100"** (1% por trade con stop) — es un
> **grid**, perfil de riesgo 6-15% por evento. Otro animal.

## Escala de pip (verificado en el código, no supuesto)
No existe input `PipSizeOverride`. La escala la deriva `StratPip()`:
`(digits == 3 || 5 || 6) ? Point*10 : Point`.
- **EURUSD** (5 dígitos): `Point*10 = 0.0001` = pip estándar. **Correcto, sin tocar nada.**
  Para 0.01 lote, 1 pip = **$0.10** de P/L.
- (Nota: en XAUUSDm esto da `0.01` → 1 pip = **$0.01**, no $0.10. El oro corre a 1/10 de la
  escala que sugiere CLAUDE.md; pendiente de revisar en master.)

## Pasos para desplegar mañana (en el terminal DEMO)
1. Cuenta **demo** aparte (o cambiar símbolo en un demo existente). Nunca real.
2. Añadir **EURUSD** al Market Watch.
3. Adjuntar Cerberus a un gráfico EURUSD M1 y **cargar** `config/Cerberus_EURUSD.set`
   (MetaEditor/ventana de inputs -> Load), o editar el `.chr` con el terminal cerrado.
4. Verificar en `ng_status.json` `config:{}` que quedó `symbol:EURUSD`, TP 15, grid 25.
5. WebRequest ya está permitido (mismo host de noticias).

No hace falta recompilar ni cambiar binario — el EA es agnóstico al símbolo, solo cambian
los inputs.

## Config (escalada a $100)
| Input | Valor | Nota |
|---|---|---|
| Symbol_Traded | EURUSD | |
| TakeProfit_Pips | 15 | $1.50 en 0.01; spread ~1 pip -> ratio sano (a diferencia del oro) |
| GridStep_Pips | 25 | niveles $2.50 aparte |
| Lot_Fixed | 0.01 | $0.10/pip |
| MaxSpread_Points | 20 | = 2 pips (EURUSD es apretado; oro era 240) |
| MaxGrid_Levels | 4 | tope duro de niveles |
| DailyLoss_USD | 15 | regla E a -15% |
| BasketStop_USD | 6 | seguro de cola ~6% |
| TrendBrake_MaxDistPips | 50 | punto de partida; ajustar en demo |
| Capital_Base / PerLevel | 100 / 25 | ~4 niveles |

## Qué medir (durante el soak)
- **Net USD**, no win rate (el win rate engaña — ya medido).
- Que el freno mantenga las canastas chicas en las caídas.
- Si el basket stop ($6) llega a dispararse (`hits_today`).
- Comparar contra no hacer nada: ¿crece de a pocos o sangra lento?

Si en demo crece de a pocos y sobrevive las caídas, recién ahí se habla de $100 reales.
