let work_hours_per_day

export async function initPunchCardCount(lv) {

  lv.handleEvent('countPunchCard', function (data) {
    work_hours_per_day = data.work_hours_per_day
    countPunchCard(lv)
  })

}

export function countPunchCard(lv) {
  const po = make_punch_objects()
  lv.pushEvent("punch_card_counted", { nh: sum_to_days(po, 'nh'), hw: sum_to_days(po, 'hw'), ot: sum_to_days(po, 'ot') })
}

function make_punch_objects() {
  const rows = Array.prototype.slice.call(document.getElementsByClassName('punch-rows'))

  return rows.map((el) => {
    return {
      hw: +el.getElementsByClassName('worked-hours')[0].innerText,
      date: el.getElementsByClassName('date')[0].innerText,
      day: el.getElementsByClassName('day')[0].innerText,
      holiday: el.getElementsByClassName('holiday')[0].innerText,
      ot: +el.getElementsByClassName('ot-hours')[0].innerText,
      nh: +el.getElementsByClassName('normal-hours')[0].innerText
    }
  })
}

function sunday_worked_count(po) {
  po.map((el) => {
    if (el.day == "Sunday" && nh >= work_hours_per_day / 2) {
      1
    } else {
      0
    }
  })
}



function sum_to_days(objs, field) {
  let sum = 0
  for (let obj of objs) {
    sum += obj[field]
  }
  return ((sum) / work_hours_per_day).toFixed(2)
}