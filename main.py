# -*- coding: utf-8 -*-
# 说明：
# - 初次请求仅抓取"当前学期"的课表；其它学期仅返回元数据，前端按需懒加载
# - 新增接口 /timetable/semester-weeks 支持按 sem_id 懒加载指定学期前 N 周（支持复用 session_id）
# - 保留原有浏览器池、内存监控与资源清理逻辑
# - 修复课程信息重复问题：正确解析HTML结构，分别提取课程名、班级、教师、地点
# - 改进点：
#   1) /timetable 返回 session_id，便于前端缓存复用
#   2) /timetable 为 sem/week 下拉数据增加一次兜底重试
#   3) /timetable 保证 default_semester/default_week 始终有值（兜底）
#   4) 即便没有抓到周数据，也会返回 all_semesters_meta + default_semester/default_week，前端可“激进模式”进入并懒加载

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from fastapi.responses import JSONResponse
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import (
    TimeoutException,
    NoAlertPresentException,
    UnexpectedAlertPresentException,
    SessionNotCreatedException,
)
from selenium.webdriver.chrome.options import Options
from bs4 import BeautifulSoup
import base64
import os
import time
import re
import requests
from queue import Queue, Empty
import threading
from fastapi.middleware.cors import CORSMiddleware
import datetime
import gc
import psutil

app = FastAPI()

# 浏览器池参数
POOL_SIZE = 5
driver_pool = Queue(maxsize=POOL_SIZE)
driver_lock = threading.Lock()
drivers = {}
driver_expiry = {}
driver_usage_count = {}  # 跟踪每个driver的使用次数
MAX_USAGE_PER_DRIVER = 15  # 每个driver最多使用15次

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class TimetableRequest(BaseModel):
    session_id: str
    username: str
    password: str
    captcha: str | None = None

class SemesterWeeksRequest(BaseModel):
    # 懒加载指定学期的课表；优先复用 session_id，避免再次登录与验证码
    username: str | None = None
    password: str | None = None
    captcha: str | None = None
    session_id: str | None = None
    sem_id: str
    max_weeks: int = 19

def memory_usage_mb():
    """获取当前进程的内存使用量(MB)"""
    return psutil.Process().memory_info().rss / 1024 / 1024

def close_alert_if_present(driver):
    """关闭可能出现的alert并返回其文本"""
    try:
        alert = driver.switch_to.alert
        alert_text = alert.text
        alert.accept()
        return alert_text
    except NoAlertPresentException:
        return None

def create_driver():
    """创建优化的Chrome浏览器实例"""
    chrome_options = Options()
    # 更稳健的无头组合
    chrome_options.add_argument("--headless=new")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")

    # 减少内存使用的关键选项
    chrome_options.add_argument("--disable-extensions")
    chrome_options.add_argument("--disable-notifications")
    chrome_options.add_argument("--disable-accelerated-2d-canvas")
    # chrome_options.add_argument("--disable-webgl")  # 如无特殊需要可不禁用
    chrome_options.add_argument("--disable-background-timer-throttling")
    chrome_options.add_argument("--disable-renderer-backgrounding")
    chrome_options.add_argument("--disable-backgrounding-occluded-windows")
    chrome_options.add_argument("--disable-client-side-phishing-detection")
    chrome_options.add_argument("--disable-component-extensions-with-background-pages")
    chrome_options.add_argument("--disable-default-apps")
    chrome_options.add_argument("--disable-features=TranslateUI,BlinkGenPropertyTrees")
    chrome_options.add_argument("--disable-ipc-flooding-protection")
    chrome_options.add_argument("--disable-hang-monitor")
    chrome_options.add_argument("--disable-prompt-on-repost")
    chrome_options.add_argument("--disable-sync")
    chrome_options.add_argument("--disable-domain-reliability")
    chrome_options.add_argument("--disable-breakpad")
    chrome_options.add_argument("--metrics-recording-only")
    chrome_options.add_argument("--no-first-run")
    chrome_options.add_argument("--safebrowsing-disable-auto-update")
    chrome_options.add_argument("--password-store=basic")
    chrome_options.add_argument("--use-mock-keychain")
    chrome_options.add_argument("--disable-site-isolation-trials")
    chrome_options.add_argument("--disable-features=VizDisplayCompositor")

    # 设置JavaScript内存限制
    chrome_options.add_argument("--js-flags=--max_old_space_size=256")

    # 设置窗口大小
    chrome_options.add_argument("--window-size=1200,800")

    # 禁用自动化检测
    chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
    chrome_options.add_experimental_option("useAutomationExtension", False)

    # 设置用户代理
    chrome_options.add_argument(
        "user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"
    )

    try:
        return webdriver.Chrome(options=chrome_options)
    except SessionNotCreatedException:
        # 降级重试
        chrome_options = Options()
        chrome_options.add_argument("--headless=new")
        chrome_options.add_argument("--no-sandbox")
        chrome_options.add_argument("--disable-dev-shm-usage")
        chrome_options.add_argument("--disable-gpu")
        chrome_options.add_argument("--window-size=1200,800")
        chrome_options.add_experimental_option("excludeSwitches", ["enable-automation"])
        chrome_options.add_experimental_option("useAutomationExtension", False)
        chrome_options.add_argument("user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
        return webdriver.Chrome(options=chrome_options)

def get_driver(timeout=10):
    """从池中获取浏览器实例（惰性创建）"""
    try:
        driver = driver_pool.get_nowait()
    except Empty:
        # 惰性创建，失败抛 503
        try:
            driver = create_driver()
        except Exception as e:
            raise HTTPException(status_code=503, detail=f"Chrome 启动失败: {e}")

    # 检查driver使用次数
    driver_id = id(driver)
    if driver_usage_count.get(driver_id, 0) >= MAX_USAGE_PER_DRIVER:
        try:
            driver.quit()
        except:
            pass
        driver = create_driver()
        driver_usage_count[driver_id] = 0

    return driver

def release_driver(driver):
    """将浏览器实例释放回池中"""
    try:
        # 清除cookies和缓存
        driver.delete_all_cookies()
        driver.execute_script("window.localStorage.clear();")
        driver.execute_script("window.sessionStorage.clear();")

        # 记录使用次数
        driver_id = id(driver)
        driver_usage_count[driver_id] = driver_usage_count.get(driver_id, 0) + 1

        driver_pool.put(driver)
    except Exception:
        # 如果driver有问题，创建新的
        try:
            driver.quit()
        except:
            pass
        try:
            driver_pool.put(create_driver())
        except:
            pass

def cleanup_drivers():
    """定期清理过期的浏览器实例"""
    while True:
        time.sleep(60)  # 每分钟检查一次
        current_time = time.time()
        expired_sessions = []

        with driver_lock:
            for session_id, expiry_time in list(driver_expiry.items()):
                if current_time - expiry_time > 300:  # 5分钟未使用
                    try:
                        driver = drivers[session_id]
                        driver.quit()
                    except Exception:
                        pass
                    expired_sessions.append(session_id)

            for session_id in expired_sessions:
                drivers.pop(session_id, None)
                driver_expiry.pop(session_id, None)

def monitor_memory():
    """监控内存使用并自动清理"""
    while True:
        memory_usage = memory_usage_mb()
        print(f"当前内存使用: {memory_usage:.2f}MB")

        # 如果内存使用超过阈值，清理一些浏览器实例
        if memory_usage > 400:
            print("内存使用过高，开始清理...")
            with driver_lock:
                # 清理过期的driver
                current_time = time.time()
                expired_sessions = []

                for session_id, expiry_time in list(driver_expiry.items()):
                    if current_time - expiry_time > 180:  # 3分钟未使用
                        try:
                            driver = drivers[session_id]
                            driver.quit()
                        except Exception:
                            pass
                        expired_sessions.append(session_id)

                for session_id in expired_sessions:
                    drivers.pop(session_id, None)
                    driver_expiry.pop(session_id, None)

                # 如果仍然过高，清理部分浏览器池
                if memory_usage_mb() > 400 and not driver_pool.empty():
                    try:
                        for _ in range(min(2, driver_pool.qsize())):
                            driver = driver_pool.get_nowait()
                            driver.quit()
                    except:
                        pass

        time.sleep(30)  # 每30秒检查一次

# 初始化 driver 池（惰性创建可将此省略；保留少量实例也可）
for _ in range(POOL_SIZE - min(POOL_SIZE, driver_pool.qsize())):
    try:
        driver_pool.put(create_driver())
    except:
        break

# 启动清理和监控线程
threading.Thread(target=cleanup_drivers, daemon=True).start()
threading.Thread(target=monitor_memory, daemon=True).start()

@app.get("/captcha")
async def get_captcha():
    """获取登录页验证码（base64）并分配 session_id。为避免占用，4分钟未使用会自动释放。"""
    if memory_usage_mb() > 500:
        raise HTTPException(status_code=503, detail="服务器内存不足，请稍后再试")

    driver = get_driver()
    try:
        t0 = time.time()
        driver.get("https://cas.cdp.edu.cn/lyuapServer/login?service=https://aic.cdp.edu.cn/xsgl/xs/login_CDSSO.aspx")
        captcha_img = WebDriverWait(driver, 15).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "img[alt='logo']"))
        )
        captcha_src = captcha_img.get_attribute('src')
        if captcha_src and captcha_src.startswith('data:image'):
            session_id = os.urandom(16).hex()
            drivers[session_id] = driver  # 绑定 session_id 和 driver
            driver_expiry[session_id] = time.time()

            # 4分钟未用自动释放
            def auto_release_driver(sid):
                time.sleep(240)
                if sid in drivers:
                    print(f"session_id {sid} 超时未用，自动释放 driver")
                    try:
                        drivers[sid].quit()
                    except Exception:
                        pass
                    drivers.pop(sid, None)
                    driver_expiry.pop(sid, None)

            threading.Thread(target=auto_release_driver, args=(session_id,), daemon=True).start()
            t1 = time.time()
            print(f"验证码接口耗时: {t1 - t0:.2f}s")
            print(f"driver_pool size: {driver_pool.qsize()}")
            return {
                "session_id": session_id,
                "captcha_base64": captcha_src
            }
        else:
            raise HTTPException(status_code=400, detail="未能获取验证码图片")
    except Exception as e:
        # 若失败则释放回池（或重建）
        release_driver(driver)
        raise HTTPException(status_code=500, detail=str(e))

def parse_course_content(cell):
    """解析课程信息，避免重复内容"""
    # 查找课程信息div
    course_info = cell.find("div", class_="courseInfo")
    if not course_info:
        return None
    
    # 分别提取课程名、班级、教师、地点
    course_name = ""
    class_info = ""
    teacher = ""
    location = ""
    
    # 提取课程名（第一个span）
    course_name_span = course_info.find("span")
    if course_name_span:
        course_name = course_name_span.get_text(strip=True)
    
    # 提取班级信息（class="teachCls"的span）
    class_span = course_info.find("span", class_="teachCls")
    if class_span:
        class_info = class_span.get_text(strip=True)
    
    # 提取教师信息（class="teacher"的span）
    teacher_span = course_info.find("span", class_="teacher")
    if teacher_span:
        teacher = teacher_span.get_text(strip=True)
    
    # 提取地点信息（class="place"的span）
    place_span = course_info.find("span", class_="place")
    if place_span:
        location = place_span.get_text(strip=True)
    
    # 组合成完整的课程信息
    content_parts = []
    if course_name:
        content_parts.append(course_name)
    if class_info:
        content_parts.append(class_info)
    if teacher:
        content_parts.append(teacher)
    if location:
        content_parts.append(location)
    
    content = " ".join(content_parts)
    return content if content else None

@app.post("/timetable")
async def get_timetable(req: TimetableRequest):
    """
    登录并只返回元数据与默认项（不抓周数据，交给前端懒加载）。
    """
    if memory_usage_mb() > 500:
        raise HTTPException(status_code=503, detail="服务器内存不足，请稍后再试")

    driver = drivers.get(req.session_id)
    if not driver:
        raise HTTPException(status_code=400, detail="无效的 session_id")

    try:
        # 登录前验证码检查
        captcha_img = driver.find_element(By.CSS_SELECTOR, "img[alt='logo']")
        captcha_src = captcha_img.get_attribute('src')
        if not req.captcha:
            return {
                "session_id": req.session_id,
                "need_manual_captcha": True,
                "force_refresh": False,
                "message": "请手动输入验证码"
            }

        # 登录
        driver.find_element(By.ID, "userName").clear()
        driver.find_element(By.ID, "userName").send_keys(req.username)
        driver.find_element(By.ID, "password").clear()
        driver.find_element(By.ID, "password").send_keys(req.password)
        driver.find_element(By.ID, "captcha").clear()
        driver.find_element(By.ID, "captcha").send_keys(req.captcha)
        driver.find_element(By.CLASS_NAME, "index-submit-36Dah").click()

        # 等待登录结果（不进入抓周）
        try:
            WebDriverWait(driver, 30).until(
                lambda d: "ticket=" in d.current_url or "Default.aspx" in d.current_url
            )
        except Exception:
            return {
                "session_id": req.session_id,
                "need_manual_captcha": True,
                "captcha_base64": captcha_src,
                "message": "验证码错误或过期，请手动输入"
            }

        if "login_CDSSO.aspx?ticket=" in driver.current_url:
            WebDriverWait(driver, 30).until(lambda d: "Default.aspx" in d.current_url)

        # 进入“周课表”页面（仅为拿下拉选项；不抓页面表格）
        wait = WebDriverWait(driver, 15)
        try:
            schedule_btn = wait.until(EC.element_to_be_clickable((By.XPATH, '//a[@title="周课表"]')))
        except Exception:
            schedule_btn = wait.until(EC.element_to_be_clickable((By.PARTIAL_LINK_TEXT, "周课表")))
        schedule_btn.click()
        driver.switch_to.window(driver.window_handles[-1])
        wait.until(EC.url_contains("weekCourseTable.do"))
        time.sleep(1.0)

        # 读取下拉（带一次兜底重试）
        sem_options = driver.execute_script("return mini.get('semId').getData();") or []
        week_options = driver.execute_script("return mini.get('weekId').getData();") or []
        if not sem_options or not week_options:
            time.sleep(0.6)
            sem_options = driver.execute_script("return mini.get('semId').getData();") or sem_options
            week_options = driver.execute_script("return mini.get('weekId').getData();") or week_options

        def _val_name(opt):
            return (
                opt.get('weekId') or opt.get('id') or opt.get('value') or opt.get('semId') or '',
                opt.get('weekName') or opt.get('name') or opt.get('text') or opt.get('semName') or str(opt)
            )

        # 元数据
        all_semesters_meta = []
        for sem in sem_options:
            sem_value, sem_name = _val_name(sem)
            all_semesters_meta.append({"sem_id": sem_value, "sem_name": sem_name})

        # 推断“当前学期”并给默认值
        now = datetime.datetime.now()
        if now.month >= 9:
            target_names = [f"{now.year}-{now.year + 1}学年秋季学期"]
        elif now.month >= 3:
            target_names = [f"{now.year - 1}-{now.year}学年春季学期"]
        else:
            target_names = [f"{now.year - 1}-{now.year}学年秋季学期"]

        current_sem_name = None
        for sem in sem_options:
            _, sem_name = _val_name(sem)
            if any(t in sem_name for t in target_names):
                current_sem_name = sem_name
                break
        if current_sem_name is None and all_semesters_meta:
            current_sem_name = all_semesters_meta[0]["sem_name"]

        default_week = None
        if week_options:
            _, default_week_name = _val_name(week_options[0])
            default_week = default_week_name

        # 会话续期
        driver_expiry[req.session_id] = time.time()

        # 关键：不返回任何 weeks，semesters 为空数组，前端进入后再懒加载
        return {
            "session_id": req.session_id,
            "semesters": [],  # 不返回周数据，立即返回
            "default_semester": current_sem_name,
            "default_week": default_week,
            "all_semesters_meta": all_semesters_meta,
            "lazy_loading": True
        }

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        try:
            if req.session_id in drivers:
                driver_expiry[req.session_id] = time.time()
        except:
            pass

@app.post("/timetable/semester-weeks")
async def get_semester_weeks(req: SemesterWeeksRequest):
    """
    懒加载指定学期的课表（默认前 max_weeks 周）。
    优先复用 session_id 对应的已登录会话；若无则重新登录（需要有效验证码）。
    """
    if memory_usage_mb() > 500:
        raise HTTPException(status_code=503, detail="服务器内存不足，请稍后再试")

    # 优先复用已有会话
    if req.session_id and req.session_id in drivers:
        driver = drivers[req.session_id]
        try:
            # 尝试确保在"周课表"页
            try:
                WebDriverWait(driver, 2).until(EC.url_contains("weekCourseTable.do"))
            except TimeoutException:
                # 如果不在，尝试点击"周课表"
                wait = WebDriverWait(driver, 5)
                try:
                    schedule_btn = wait.until(EC.element_to_be_clickable((By.XPATH, '//a[@title="周课表"]')))
                except Exception:
                    schedule_btn = wait.until(EC.element_to_be_clickable((By.PARTIAL_LINK_TEXT, "周课表")))
                schedule_btn.click()
                driver.switch_to.window(driver.window_handles[-1])
                wait.until(EC.url_contains("weekCourseTable.do"))
                time.sleep(2)

            sem_options = driver.execute_script("return mini.get('semId').getData();") or []
            week_options = driver.execute_script("return mini.get('weekId').getData();") or []

            def _val_name(opt):
                return (
                    opt.get('weekId') or opt.get('id') or opt.get('value') or opt.get('semId') or '',
                    opt.get('weekName') or opt.get('name') or opt.get('text') or opt.get('semName') or str(opt)
                )

            matched_sem = None
            for sem in sem_options:
                sem_value, sem_name = _val_name(sem)
                if sem_value == req.sem_id:
                    matched_sem = (sem_value, sem_name)
                    break
            if not matched_sem:
                raise HTTPException(status_code=400, detail="无效的 sem_id")

            sem_value, sem_name = matched_sem
            semester_weeks = []
            total_weeks = max(1, req.max_weeks)

            for widx, wopt in enumerate(week_options[:total_weeks]):
                if widx % 2 == 0:
                    gc.collect()
                week_value, week_name = _val_name(wopt)
                try:
                    driver.execute_script(f"""
                        mini.get('semId').setValue('{sem_value}');
                        mini.get('semId').setText('{sem_name}');
                        mini.get('semId').fire('valuechanged');
                        mini.get('weekId').setValue('{week_value}');
                        mini.get('weekId').setText('{week_name}');
                        mini.get('weekId').fire('valuechanged');
                    """)
                except Exception:
                    continue

                alert_text = close_alert_if_present(driver)
                if alert_text:
                    continue

                try:
                    WebDriverWait(driver, 5).until(
                        EC.presence_of_element_located((By.CSS_SELECTOR, "table#table .courseInfo"))
                    )
                except Exception:
                    continue

                html = driver.page_source
                soup = BeautifulSoup(html, "lxml")
                table = soup.find("table", {"id": "table"})
                if not table or not table.find_all("tr"):
                    continue

                header = table.find("tr")
                days = [cell.get_text(strip=True) for cell in header.find_all("td")][1:]
                week_courses = {day: [] for day in days}
                for row in table.find_all("tr")[1:]:
                    cells = row.find_all("td")
                    if not cells:
                        continue
                    period = cells[0].get_text(strip=True).replace("\n", "")
                    for i, cell in enumerate(cells[1:]):
                        content = parse_course_content(cell)
                        if content:
                            week_courses[days[i]].append({"period": period, "content": content})

                semester_weeks.append({
                    "week_id": week_value,
                    "week_name": week_name,
                    "courses": week_courses
                })

            # 刷新会话过期时间
            driver_expiry[req.session_id] = time.time()
            return {
                "sem_id": sem_value,
                "sem_name": sem_name,
                "weeks": semester_weeks,
                # 可选返回：前端通常不需要
                # "session_id": req.session_id
            }
        except HTTPException:
            raise
        except Exception as e:
            import traceback
            traceback.print_exc()
            raise HTTPException(status_code=500, detail=str(e))

    # 无可复用会话：独立创建并登录（需要有效验证码）
    if not (req.username and req.password and req.captcha):
        raise HTTPException(status_code=400, detail="会话已失效，请提供用户名、密码与最新验证码")

    driver = create_driver()
    try:
        driver.get("https://cas.cdp.edu.cn/lyuapServer/login?service=https://aic.cdp.edu.cn/xsgl/xs/login_CDSSO.aspx")

        # 登录
        WebDriverWait(driver, 15).until(EC.presence_of_element_located((By.ID, "userName")))
        driver.find_element(By.ID, "userName").send_keys(req.username)
        driver.find_element(By.ID, "password").send_keys(req.password)
        driver.find_element(By.ID, "captcha").send_keys(req.captcha)
        driver.find_element(By.CLASS_NAME, "index-submit-36Dah").click()

        # 等待登录（30s）
        try:
            WebDriverWait(driver, 30).until(
                lambda d: "ticket=" in d.current_url or "Default.aspx" in d.current_url
            )
        except TimeoutException:
            alert_text = close_alert_if_present(driver)
            detail = "验证码可能已过期，请刷新并重试"
            if alert_text:
                detail = alert_text
            raise HTTPException(status_code=401, detail=detail)

        if "login_CDSSO.aspx?ticket=" in driver.current_url:
            WebDriverWait(driver, 30).until(lambda d: "Default.aspx" in d.current_url)

        # 进入"周课表"
        wait = WebDriverWait(driver, 10)
        schedule_btn = wait.until(
            EC.element_to_be_clickable((By.XPATH, '//a[@title="周课表"]'))
        )
        schedule_btn.click()
        driver.switch_to.window(driver.window_handles[-1])
        wait.until(EC.url_contains("weekCourseTable.do"))
        time.sleep(1)

        sem_options = driver.execute_script("return mini.get('semId').getData();") or []
        week_options = driver.execute_script("return mini.get('weekId').getData();") or []

        def _val_name(opt):
            return (
                opt.get('weekId') or opt.get('id') or opt.get('value') or opt.get('semId') or '',
                opt.get('weekName') or opt.get('name') or opt.get('text') or opt.get('semName') or str(opt)
            )

        # 校验 sem_id 是否存在
        matched_sem = None
        for sem in sem_options:
            sem_value, sem_name = _val_name(sem)
            if sem_value == req.sem_id:
                matched_sem = (sem_value, sem_name)
                break
        if not matched_sem:
            raise HTTPException(status_code=400, detail="无效的 sem_id")

        sem_value, sem_name = matched_sem
        semester_weeks = []
        total_weeks = max(1, req.max_weeks)

        for widx, wopt in enumerate(week_options[:total_weeks]):
            if widx % 2 == 0:
                gc.collect()

            week_value, week_name = _val_name(wopt)
            try:
                driver.execute_script(f"""
                    mini.get('semId').setValue('{sem_value}');
                    mini.get('semId').setText('{sem_name}');
                    mini.get('semId').fire('valuechanged');
                    mini.get('weekId').setValue('{week_value}');
                    mini.get('weekId').setText('{week_name}');
                    mini.get('weekId').fire('valuechanged');
                """)
            except Exception:
                continue

            alert_text = close_alert_if_present(driver)
            if alert_text:
                continue

            try:
                WebDriverWait(driver, 5).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, "table#table .courseInfo"))
                )
            except Exception:
                continue

            html = driver.page_source
            soup = BeautifulSoup(html, "lxml")
            table = soup.find("table", {"id": "table"})
            if not table or not table.find_all("tr"):
                continue

            header = table.find("tr")
            days = [cell.get_text(strip=True) for cell in header.find_all("td")][1:]
            week_courses = {day: [] for day in days}
            for row in table.find_all("tr")[1:]:
                cells = row.find_all("td")
                if not cells:
                    continue
                period = cells[0].get_text(strip=True).replace("\n", "")
                for i, cell in enumerate(cells[1:]):
                    content = parse_course_content(cell)
                    if content:
                        week_courses[days[i]].append({"period": period, "content": content})

            semester_weeks.append({
                "week_id": week_value,
                "week_name": week_name,
                "courses": week_courses
            })

        return {
            "sem_id": sem_value,
            "sem_name": sem_name,
            "weeks": semester_weeks
        }
    except HTTPException:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        try:
            driver.quit()
        except:
            pass

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)