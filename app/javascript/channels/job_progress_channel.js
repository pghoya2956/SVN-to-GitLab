import consumer from "./consumer"

export function subscribeToJobProgress(jobId) {
  return consumer.subscriptions.create(
    { 
      channel: "JobProgressChannel",
      job_id: jobId 
    },
    {
      connected() {
        console.log("Connected to job progress channel")
      },

      disconnected() {
        console.log("Disconnected from job progress channel")
      },

      received(data) {
        updateProgressUI(data)
      }
    }
  )
}

function updateProgressUI(data) {
  // 진행률 바 업데이트
  const progressBar = document.querySelector('.migration-progress-bar')
  if (progressBar) {
    progressBar.style.width = `${data.progress_percentage}%`
    progressBar.setAttribute('aria-valuenow', data.progress_percentage)
    progressBar.textContent = `${data.progress_percentage}%`
  }
  
  // 상세 정보 업데이트
  updateElement('#current-revision', `${data.current_revision} / ${data.total_revisions}`)
  updateElement('#elapsed-time', data.elapsed_time)
  updateElement('#eta', data.eta)
  updateElement('#processing-speed', `${data.processing_speed} 리비전/초`)
  updateElement('#current-commit', data.current_commit_message || '-')
  
  // 처리 속도 차트 업데이트
  if (window.updateProgressChart) {
    window.updateProgressChart(data.processing_speed)
  }
  
  // 상태에 따른 UI 변경
  if (data.status === 'completed') {
    showCompletionMessage()
  } else if (data.status === 'failed') {
    showErrorMessage()
  }
}

function updateElement(selector, value) {
  const element = document.querySelector(selector)
  if (element) {
    element.textContent = value
  }
}

function showCompletionMessage() {
  const progressMonitor = document.querySelector('.progress-monitor')
  if (progressMonitor) {
    const alert = document.createElement('div')
    alert.className = 'alert alert-success mt-3'
    alert.innerHTML = `
      <h4 class="alert-heading">마이그레이션 완료!</h4>
      <p>SVN 저장소가 성공적으로 GitLab으로 마이그레이션되었습니다.</p>
    `
    progressMonitor.appendChild(alert)
  }
}

function showErrorMessage() {
  const progressMonitor = document.querySelector('.progress-monitor')
  if (progressMonitor) {
    const alert = document.createElement('div')
    alert.className = 'alert alert-danger mt-3'
    alert.innerHTML = `
      <h4 class="alert-heading">마이그레이션 실패</h4>
      <p>마이그레이션 중 오류가 발생했습니다. 로그를 확인해주세요.</p>
    `
    progressMonitor.appendChild(alert)
  }
}