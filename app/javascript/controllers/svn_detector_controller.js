import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "spinner", "buttonText", "result", "structureInfo", "progressLog", "progressCard"]
  
  async detect(event) {
    event.preventDefault();
    const button = event.currentTarget;
    const url = button.dataset.url;
    const repositoryId = button.dataset.repositoryId;
    
    // 이미 감지된 구조가 있는지 확인
    if (button.dataset.hasStructure === "true") {
      if (!confirm("이미 감지된 SVN 구조가 있습니다. 다시 감지하시겠습니까?")) {
        return;
      }
    }
    
    // 즉시 진행 중 UI로 변경
    this.showDetectionInProgress(repositoryId);
    
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'X-CSRF-Token': document.querySelector('[name="csrf-token"]').content,
          'Accept': 'application/json',
          'Content-Type': 'application/json'
        }
      });
      
      const data = await response.json();
      
      if (!data.success) {
        this.showError(data.error || "SVN 구조 감지에 실패했습니다.");
        // 실패 시 원래 상태로 복원
        setTimeout(() => {
          location.reload();
        }, 2000);
      }
      // 성공 시에는 ActionCable이 자동으로 업데이트하므로 아무것도 하지 않음
    } catch (error) {
      this.showError("네트워크 오류가 발생했습니다. 잠시 후 다시 시도해주세요.");
      console.error('Detection error:', error);
      // 에러 시 원래 상태로 복원
      setTimeout(() => {
        location.reload();
      }, 2000);
    }
  }
  
  showDetectionInProgress(repositoryId, jobId = null) {
    // 기존 구조 정보를 진행 중 UI로 즉시 교체
    if (this.hasStructureInfoTarget) {
      this.structureInfoTarget.innerHTML = `
        <div class="alert alert-info p-2 mb-2" data-svn-detector-target="progressCard">
          <div class="d-flex align-items-center">
            <div class="spinner-border spinner-border-sm me-2" role="status">
              <span class="visually-hidden">Loading...</span>
            </div>
            <div class="flex-grow-1">
              <strong>구조 감지 진행 중...</strong><br>
              <small>다른 페이지로 이동해도 계속 진행됩니다.</small>
            </div>
          </div>
          <div class="mt-2 p-2 bg-dark text-light rounded" style="font-family: monospace; font-size: 0.75rem; max-height: 150px; overflow-y: auto;">
            <div data-svn-detector-target="progressLog">
              <div class="text-warning">🔄 구조 감지를 시작합니다...</div>
            </div>
          </div>
          ${jobId ? `<div class="mt-2">
            <a href="/jobs/${jobId}" class="btn btn-sm btn-primary" target="_blank">
              <i class="bi bi-eye me-1"></i>전체 로그 보기
            </a>
          </div>` : ''}
        </div>
      `;
      
      // SVN 구조 섹션으로 스크롤
      this.structureInfoTarget.scrollIntoView({ behavior: 'smooth', block: 'center' });
      
      // 섹션에 하이라이트 효과 추가
      const structureSection = this.structureInfoTarget.closest('.col-md-4');
      if (structureSection) {
        structureSection.classList.add('highlight-section');
        setTimeout(() => {
          structureSection.classList.remove('highlight-section');
        }, 2000);
      }
    }
  }
  
  addProgressMessage(message) {
    // 진행 중인 로그 메시지 추가
    if (this.hasProgressLogTarget) {
      const logDiv = document.createElement('div');
      
      // 메시지 타입에 따라 색상 결정
      let className = 'text-light';
      if (message.includes('✅') || message.includes('완료')) {
        className = 'text-success';
      } else if (message.includes('❌') || message.includes('실패') || message.includes('ERROR')) {
        className = 'text-danger';
      } else if (message.includes('⚠️') || message.includes('경고')) {
        className = 'text-warning';
      } else if (message.includes('🔍') || message.includes('확인')) {
        className = 'text-info';
      } else if (message.includes('📊') || message.includes('결과')) {
        className = 'text-primary fw-bold';
      } else if (message.includes('=====')) {
        className = 'text-secondary';
      }
      
      logDiv.className = className;
      logDiv.style.fontSize = '0.7rem';
      logDiv.style.lineHeight = '1.2';
      logDiv.textContent = message;
      
      this.progressLogTarget.appendChild(logDiv);
      
      // 최대 20줄만 유지 (메모리 절약)
      while (this.progressLogTarget.children.length > 20) {
        this.progressLogTarget.removeChild(this.progressLogTarget.firstChild);
      }
      
      // 자동 스크롤
      this.progressLogTarget.parentElement.scrollTop = this.progressLogTarget.parentElement.scrollHeight;
    }
  }
  
  showLoading() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.remove('d-none');
    }
    if (this.hasButtonTextTarget) {
      this.buttonTextTarget.textContent = "SVN 구조 분석 중...";
    }
    this.buttonTarget.disabled = true;
    
    // 기존 결과 영역 비우기 (중복 로딩 표시 제거)
    if (this.hasResultTarget) {
      this.resultTarget.innerHTML = '';
    }
  }
  
  hideLoading() {
    if (this.hasSpinnerTarget) {
      this.spinnerTarget.classList.add('d-none');
    }
    if (this.hasButtonTextTarget) {
      // 버튼 텍스트를 원래대로 복원 (다시 감지 버튼인지 확인)
      const originalText = this.buttonTarget.querySelector('.bi-arrow-clockwise') ? 
        '<i class="bi bi-arrow-clockwise me-1"></i>다시 감지' : 
        '<i class="bi bi-search me-1"></i>구조 감지하기';
      this.buttonTextTarget.innerHTML = originalText;
    }
    this.buttonTarget.disabled = false;
  }
  
  updateUI(data) {
    if (!data.structure) return;
    
    // 전체 페이지를 새로고침하여 진행 표시기와 모든 UI를 업데이트
    // 부드러운 전환을 위해 약간의 지연 후 새로고침
    setTimeout(() => {
      location.reload();
    }, 500);
  }
  
  showSuccess(message) {
    // 성공 알림 표시
    const alert = document.createElement('div');
    alert.className = 'alert alert-success alert-dismissible fade show mt-3';
    alert.innerHTML = `
      <i class="bi bi-check-circle-fill me-2"></i>
      <strong>성공!</strong> ${message}
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    `;
    
    if (this.hasResultTarget) {
      this.resultTarget.appendChild(alert);
    }
    
    // 다음 단계 안내
    setTimeout(() => {
      if (this.hasResultTarget) {
        this.resultTarget.innerHTML += `
          <div class="alert alert-info mt-2">
            <i class="bi bi-lightbulb me-2"></i>
            <strong>다음 단계:</strong> 이제 마이그레이션 전략을 설정할 수 있습니다.
            <a href="/repositories/${this.buttonTarget.dataset.repositoryId}/edit_strategy" 
               class="alert-link">전략 설정하기 →</a>
          </div>
        `;
      }
    }, 1000);
  }
  
  showError(message) {
    const alert = document.createElement('div');
    alert.className = 'alert alert-danger alert-dismissible fade show';
    alert.innerHTML = `
      <i class="bi bi-exclamation-triangle-fill me-2"></i>
      <strong>오류:</strong> ${message}
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    `;
    
    if (this.hasResultTarget) {
      this.resultTarget.innerHTML = '';
      this.resultTarget.appendChild(alert);
    }
  }
}