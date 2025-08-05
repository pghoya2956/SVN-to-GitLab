import { chromium, Browser, BrowserContext, Page } from '@playwright/test';
import path from 'path';

export class BrowserHelper {
  private browser?: Browser;
  private context?: BrowserContext;
  private page?: Page;

  /**
   * 프로젝트별로 격리된 브라우저 인스턴스를 생성합니다
   */
  async launch(projectName: string = 'default'): Promise<void> {
    // 프로젝트별 고유 사용자 데이터 디렉토리
    const userDataDir = path.resolve(`.playwright-profiles/${projectName}`);
    
    // Persistent context로 브라우저 실행
    this.context = await chromium.launchPersistentContext(userDataDir, {
      headless: process.env.HEADLESS !== 'false',
      args: [
        '--remote-debugging-port=0', // 랜덤 포트 사용
        '--disable-dev-shm-usage',   // Docker 환경 대응
        '--no-sandbox',              // CI 환경 대응
      ],
      // 뷰포트 설정
      viewport: { width: 1280, height: 720 },
      // 로케일 설정
      locale: 'ko-KR',
      // 타임존 설정
      timezoneId: 'Asia/Seoul',
    });

    // 첫 번째 페이지 가져오기
    this.page = this.context.pages()[0] || await this.context.newPage();
  }

  /**
   * 격리된 context에서 새 페이지 생성
   */
  async newPage(): Promise<Page> {
    if (!this.context) {
      throw new Error('Browser context not initialized');
    }
    return await this.context.newPage();
  }

  /**
   * 현재 페이지 반환
   */
  getPage(): Page {
    if (!this.page) {
      throw new Error('Page not initialized');
    }
    return this.page;
  }

  /**
   * 브라우저 종료
   */
  async close(): Promise<void> {
    if (this.context) {
      await this.context.close();
    }
    if (this.browser) {
      await this.browser.close();
    }
  }

  /**
   * 로그인 상태 저장
   */
  async saveAuthState(path: string): Promise<void> {
    if (!this.context) {
      throw new Error('Browser context not initialized');
    }
    await this.context.storageState({ path });
  }

  /**
   * 저장된 로그인 상태로 컨텍스트 생성
   */
  async createAuthenticatedContext(authStatePath: string): Promise<BrowserContext> {
    if (!this.browser) {
      this.browser = await chromium.launch({
        headless: process.env.HEADLESS !== 'false',
        args: ['--remote-debugging-port=0'],
      });
    }
    
    return await this.browser.newContext({
      storageState: authStatePath,
      viewport: { width: 1280, height: 720 },
      locale: 'ko-KR',
      timezoneId: 'Asia/Seoul',
    });
  }
}

/**
 * 프로젝트별 브라우저 인스턴스 팩토리
 */
export async function createBrowser(projectName: string): Promise<BrowserHelper> {
  const helper = new BrowserHelper();
  await helper.launch(projectName);
  return helper;
}