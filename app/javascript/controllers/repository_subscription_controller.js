import { Controller } from "@hotwired/stimulus"
import consumer from "../channels/consumer"

export default class extends Controller {
  static values = { repositoryId: Number }
  
  connect() {
    if (!this.repositoryIdValue) return;
    
    this.subscription = consumer.subscriptions.create(
      { 
        channel: "RepositoryChannel", 
        id: this.repositoryIdValue 
      },
      {
        received: (data) => {
          this.handleMessage(data);
        }
      }
    );
  }
  
  disconnect() {
    if (this.subscription) {
      this.subscription.unsubscribe();
    }
  }
  
  handleMessage(data) {
    switch(data.type) {
      case 'structure_detection_progress':
        this.handleDetectionProgress(data);
        break;
      case 'structure_detection_complete':
        this.handleDetectionComplete(data);
        break;
      case 'structure_detection_failed':
        this.handleDetectionFailed(data);
        break;
    }
  }
  
  handleDetectionProgress(data) {
    // SvnDetectorController에 진행 메시지 전달
    const svnDetectorElement = document.querySelector('[data-controller="svn-detector"]');
    if (svnDetectorElement) {
      const svnDetectorController = this.application.getControllerForElementAndIdentifier(
        svnDetectorElement, 
        'svn-detector'
      );
      if (svnDetectorController && svnDetectorController.addProgressMessage) {
        // [SvnStructureDetector] 프리픽스 제거
        const cleanMessage = data.message.replace('[SvnStructureDetector] ', '');
        svnDetectorController.addProgressMessage(cleanMessage);
      }
    }
  }
  
  handleDetectionComplete(data) {
    // 성공 알림 표시
    this.showNotification('success', data.message || 'SVN 구조 감지가 완료되었습니다!');
    
    // 3초 후 페이지 새로고침
    setTimeout(() => {
      location.reload();
    }, 3000);
  }
  
  handleDetectionFailed(data) {
    // 실패 알림 표시
    this.showNotification('danger', data.message || 'SVN 구조 감지에 실패했습니다.');
  }
  
  showNotification(type, message) {
    const container = document.getElementById('notifications-container') || this.createNotificationContainer();
    
    const alert = document.createElement('div');
    alert.className = `alert alert-${type} alert-dismissible fade show`;
    alert.innerHTML = `
      <i class="bi bi-${type === 'success' ? 'check-circle' : 'exclamation-triangle'}-fill me-2"></i>
      ${message}
      <button type="button" class="btn-close" data-bs-dismiss="alert"></button>
    `;
    
    container.appendChild(alert);
    
    // 10초 후 자동 제거
    setTimeout(() => {
      alert.remove();
    }, 10000);
  }
  
  createNotificationContainer() {
    const container = document.createElement('div');
    container.id = 'notifications-container';
    container.style.position = 'fixed';
    container.style.top = '20px';
    container.style.right = '20px';
    container.style.zIndex = '9999';
    container.style.maxWidth = '400px';
    document.body.appendChild(container);
    return container;
  }
}