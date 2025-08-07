import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["customPaths"]
  
  connect() {
    this.toggleCustomPaths()
  }
  
  toggleCustomPaths(event) {
    const layoutType = event ? event.target.value : document.getElementById('repository_layout_type')?.value
    
    if (this.hasCustomPathsTarget) {
      if (layoutType === 'custom') {
        this.customPathsTarget.classList.remove('d-none')
      } else {
        this.customPathsTarget.classList.add('d-none')
      }
    }
  }
  
  async validatePaths(event) {
    event.preventDefault()
    
    const button = event.currentTarget
    const url = button.dataset.url
    const resultDiv = document.getElementById('validation-result')
    
    // Get form values
    const trunkPath = document.getElementById('repository_custom_trunk_path').value
    const branchesPath = document.getElementById('repository_custom_branches_path').value
    const tagsPath = document.getElementById('repository_custom_tags_path').value
    
    // Show loading
    button.disabled = true
    button.innerHTML = '<span class="spinner-border spinner-border-sm me-2"></span>검증 중...'
    
    try {
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-CSRF-Token': document.querySelector('[name="csrf-token"]').content
        },
        body: JSON.stringify({
          trunk_path: trunkPath,
          branches_path: branchesPath,
          tags_path: tagsPath
        })
      })
      
      const result = await response.json()
      
      // Display results
      if (result.valid) {
        resultDiv.className = 'alert alert-success mt-2'
        resultDiv.innerHTML = '<i class="bi bi-check-circle me-2"></i>모든 경로가 유효합니다.'
      } else {
        resultDiv.className = 'alert alert-danger mt-2'
        resultDiv.innerHTML = '<i class="bi bi-x-circle me-2"></i>' + result.errors.join('<br>')
      }
      
      // Show path details
      if (result.paths) {
        let details = '<div class="mt-2 small">'
        for (const [path, info] of Object.entries(result.paths)) {
          details += `<div>${path}: ${info.message}</div>`
        }
        details += '</div>'
        resultDiv.innerHTML += details
      }
    } catch (error) {
      resultDiv.className = 'alert alert-danger mt-2'
      resultDiv.innerHTML = '<i class="bi bi-x-circle me-2"></i>검증 중 오류가 발생했습니다.'
    } finally {
      // Reset button
      button.disabled = false
      button.innerHTML = '<i class="bi bi-check-circle me-2"></i>경로 검증'
    }
  }
}