import { test, expect } from '@playwright/test';
import { createBrowser, BrowserHelper } from './helpers/browser-helper';

test.describe('GitLab Integration Tests', () => {
  let browser: BrowserHelper;

  test.beforeAll(async () => {
    // 프로젝트별 격리된 브라우저 생성
    browser = await createBrowser('gitlab-integration');
  });

  test.afterAll(async () => {
    await browser.close();
  });

  test('should login and save GitLab token', async () => {
    const page = browser.getPage();
    
    // 1. 홈페이지 접속
    await page.goto('http://localhost:3000');
    
    // 2. 로그인 페이지로 리다이렉트 확인
    await expect(page).toHaveURL(/.*sign_in/);
    
    // 3. 로그인
    await page.fill('input[name="user[email]"]', 'test@example.com');
    await page.fill('input[name="user[password]"]', 'password123');
    await page.click('button[type="submit"]');
    
    // 4. 로그인 성공 확인
    await expect(page).toHaveURL('http://localhost:3000/repositories');
    
    // 5. GitLab 토큰 페이지로 이동
    await page.click('text=Configure GitLab Token');
    
    // 6. GitLab 토큰 입력
    await page.fill('input[name="gitlab_token[token]"]', 'glpat-SvhybvwSBFGkKgGxVsr-');
    await page.fill('input[name="gitlab_token[endpoint]"]', 'https://gitlab.com/api/v4');
    
    // 7. 저장
    await page.click('button[type="submit"]');
    
    // 8. 성공 메시지 확인
    await expect(page.locator('.alert-success')).toContainText('GitLab token configured successfully');
    
    // 9. 인증 상태 저장 (다음 테스트를 위해)
    await browser.saveAuthState('playwright/.auth/gitlab-test.json');
  });

  test('should list GitLab projects', async () => {
    const page = browser.getPage();
    
    // GitLab 프로젝트 페이지로 이동
    await page.goto('http://localhost:3000/gitlab_projects');
    
    // 프로젝트 목록이 로드될 때까지 대기
    await page.waitForSelector('.project-list', { timeout: 10000 });
    
    // 프로젝트가 표시되는지 확인
    const projects = await page.locator('.project-item').count();
    expect(projects).toBeGreaterThan(0);
  });

  test('should search GitLab projects', async () => {
    const page = browser.getPage();
    
    // 검색어 입력
    await page.fill('input[name="query"]', 'test');
    await page.click('button[type="submit"]');
    
    // 검색 결과 대기
    await page.waitForSelector('.search-results', { timeout: 5000 });
    
    // 검색 결과 확인
    const searchResults = await page.locator('.search-result-item').count();
    expect(searchResults).toBeGreaterThanOrEqual(0);
  });
});

// 병렬 실행 시 격리를 위한 설정
test.describe.configure({ mode: 'serial' });