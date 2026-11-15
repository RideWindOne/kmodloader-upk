#!/bin/sh
# 独立日志页：Redroid 与 ws-scrcpy-web 两路日志，供 index.html 的“日志”页签使用
echo "Content-Type: text/html; charset=utf-8"
echo ""

cat <<'EOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
  html,body{margin:0;padding:0;background:#111418;color:#e6e9ef;
    font:14px/1.6 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif;}
  .wrap{padding:14px 16px 18px;}
  .sec{display:flex;align-items:center;justify-content:space-between;
    margin:14px 0 8px;color:#8b93a1;font-size:12px;letter-spacing:.5px;}
  .sec:first-child{margin-top:0;}
  .sec b{color:#c8cfdb;font-weight:600;font-size:13px;letter-spacing:0;}
  .hint{color:#6f7887;font-size:11px;}
  .log{background:#12161b;border-radius:8px;padding:10px 12px;color:#a9b3c1;
    font:12px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace;
    white-space:pre-wrap;word-break:break-all;
    height:calc(50vh - 60px);min-height:180px;overflow-y:auto;}
  .btns{display:flex;gap:8px;}
  button{font-family:inherit;font-size:12px;border:0;border-radius:7px;cursor:pointer;
    padding:6px 12px;background:#2a3038;color:#c8cfdb;}
  button:hover{background:#343d49;}
  button.danger{background:#5a2a30;color:#ffd6da;}
  button.danger:hover{background:#74343b;}
</style>
</head>
<body>
<div class="wrap">
  <div class="sec">
    <b>Redroid 日志</b>
    <div class="btns">
      <button id="pause" type="button">暂停</button>
      <button id="clear1" type="button">清屏</button>
      <button id="wipe1" type="button" class="danger">清空日志</button>
    </div>
  </div>
  <div class="log" id="rtlog">（加载中…）</div>

  <div class="sec">
    <b>ws-scrcpy-web 日志</b>
    <div class="btns">
      <button id="clear2" type="button">清屏</button>
      <button id="wipe2" type="button" class="danger">清空日志</button>
    </div>
  </div>
  <div class="log" id="wtlog">（加载中…）</div>
</div>

<script>
(function(){
  var paused = false;

  function pull(id, which){
    if(paused) return;
    try{
      fetch('log.sh?which=' + which + '&t=' + Date.now(), {cache:'no-store'})
        .then(function(r){ return r.text(); })
        .then(function(t){
          var el = document.getElementById(id);
          if(!el) return;
          var atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
          el.textContent = (t && t.trim()) ? t : '（暂无记录）';
          if(atBottom) el.scrollTop = el.scrollHeight;
        })
        .catch(function(){});
    }catch(e){}
  }

  function tick(){ pull('rtlog','redroid'); pull('wtlog','ws'); }
  tick();
  setInterval(tick, 3000);

  var pauseBtn = document.getElementById('pause');
  if(pauseBtn){
    pauseBtn.addEventListener('click', function(){
      paused = !paused;
      pauseBtn.textContent = paused ? '继续' : '暂停';
      if(!paused) tick();
    });
  }
  ['clear1','clear2'].forEach(function(id){
    var b = document.getElementById(id);
    if(!b) return;
    b.addEventListener('click', function(){
      var t = document.getElementById(id === 'clear1' ? 'rtlog' : 'wtlog');
      if(t) t.textContent = '（已清屏，仅影响当前显示）';
    });
  });

  function wipe(which, logId, btn){
    if(!btn || btn.disabled) return;
    if(!window.confirm('清空服务端日志文件？该操作不可恢复。')) return;
    btn.disabled = true;
    var old = btn.textContent;
    btn.textContent = '清理中…';
    fetch('log.sh?which=' + which + '&action=clear&t=' + Date.now(),
          {method:'POST', cache:'no-store'})
      .then(function(r){ return r.text(); })
      .then(function(t){
        var el = document.getElementById(logId);
        if(el) el.textContent = (t && t.trim()) ? t : '（已清空）';
      })
      .catch(function(){
        var el = document.getElementById(logId);
        if(el) el.textContent = '（清空请求失败）';
      })
      .then(function(){
        btn.disabled = false;
        btn.textContent = old;
      });
  }

  var w1 = document.getElementById('wipe1');
  if(w1) w1.addEventListener('click', function(){ wipe('redroid','rtlog',w1); });
  var w2 = document.getElementById('wipe2');
  if(w2) w2.addEventListener('click', function(){ wipe('ws','wtlog',w2); });
})();
</script>
</body>
</html>
EOF
