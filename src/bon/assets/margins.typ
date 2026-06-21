#let paper-width = 80mm
#let paper-height = 80mm
#let margin = 10mm
#let edge-margin = 0.6pt
#set page(width: paper-width, height: paper-height, margin: 0mm)
#set text(font: "Helvetica", size: 12pt)

#let tick-step = 1mm
#let tick-short = 1.5mm
#let tick-long = 3mm
#let tick-stroke = 0.25pt + black
#let border-stroke = 0.6pt + black

#let tick(dx, dy, length, side) = place(dx: dx, dy: dy)[
  #if side == "top" {
    line(angle: 90deg, length: length, stroke: tick-stroke)
  } else if side == "bottom" {
    move(dy: -length, line(angle: 90deg, length: length, stroke: tick-stroke))
  } else if side == "left" {
    line(length: length, stroke: tick-stroke)
  } else {
    move(dx: -length, line(length: length, stroke: tick-stroke))
  }
]

#let tick-count(length) = calc.floor(length / tick-step) + 1

#let calibration-page(left: margin, right: margin, top: margin, bottom: margin, body) = {
  let box-width = paper-width - left - right
  let box-height = paper-height - top - bottom
  let note-width = calc.min(box-width - 8mm, 42mm)
  let note-height = calc.min(box-height - 8mm, 42mm)

  place(dx: left, dy: top)[
    #rect(width: box-width, height: box-height, stroke: border-stroke, inset: 0pt)
  ]

  for n in range(0, tick-count(box-width)) {
    let length = if calc.rem(n, 10) == 0 { tick-long } else { tick-short }
    tick(left + n * tick-step, top, length, "top")
    tick(left + n * tick-step, top + box-height, length, "bottom")
  }

  for n in range(0, tick-count(box-height)) {
    let length = if calc.rem(n, 10) == 0 { tick-long } else { tick-short }
    tick(left, top + n * tick-step, length, "left")
    tick(left + box-width, top + n * tick-step, length, "right")
  }

  place(dx: left + (box-width - note-width) / 2, dy: top + (box-height - note-height) / 2 - 2mm)[
    #box(width: note-width, height: note-height)[
      #align(center + horizon, body)
    ]
  ]
}

#calibration-page[
  This box should have an equal 10 mm margin on all sides.
]

#pagebreak()

#calibration-page(top: edge-margin, bottom: edge-margin)[
  This box should reach almost to the top and bottom paper edges.
]
