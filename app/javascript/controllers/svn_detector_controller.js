import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "spinner", "buttonText", "result", "structureInfo"]
  
  async detect(event) {
    event.preventDefault();
    const button = event.currentTarget;
    const url = button.dataset.url;
    
    // 이미 감지된 구조가 있는지 확인
    if (button.dataset.hasStructure === "true") {
      if (!confirm("이미 감지된 SVN 구조가 있습니다. 다시 감지하시겠습니까?")) {
        return;
      }
    }
    
    // 로딩 상태 표시
    this.showLoading();
    
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
      
      if (data.success) {
        this.updateUI(data);
        this.showSuccess(data.message || "SVN 구조 감지가 완료되었습니다!");
      } else {
        this.showError(data.error || "SVN 구조 감지에 실패했습니다.");
      }
    } catch (error) {
      this.showError("네트워크 오류가 발생했습니다. 잠시 후 다시 시도해주세요.");
      console.error('Detection error:', error);
    } finally {
      this.hideLoading();
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