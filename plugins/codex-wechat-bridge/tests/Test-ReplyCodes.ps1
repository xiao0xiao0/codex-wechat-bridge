param([string]$ModulePath = (Join-Path $PSScriptRoot '..\scripts\CodexWeChatBridge.psm1'))
$ErrorActionPreference='Stop'
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('bridge-codes-'+[guid]::NewGuid().ToString('N'))
$oldState=$env:CODEX_WECHAT_BRIDGE_HOME
$oldCodex=$env:CODEX_HOME
$env:CODEX_WECHAT_BRIDGE_HOME=Join-Path $testRoot 'bridge'
$env:CODEX_HOME=Join-Path $testRoot 'codex'
try {
    $module=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    $result=& $module {
        $script:codeAssertions=0
        function Equal($Actual,$Expected,[string]$Label) {
            $script:codeAssertions++
            if($Actual -cne $Expected){throw "$Label : expected '$Expected', got '$Actual'"}
        }
        function Reject([scriptblock]$Action,[string]$Label){$caught=$false;try{& $Action | Out-Null}catch{$caught=$true};Equal $caught $true $Label}
        $root=Initialize-BridgeState
        $taskA='aaaaaaaa-1111-2222-3333-444444444444'
        $taskB='bbbbbbbb-1111-2222-3333-444444444444'
        $codeA=Get-BridgeReplyCode $taskA -ThreadName '示例任务' -Cwd $root -TurnId 'turn-old'
        $codeB=Get-BridgeReplyCode $taskB -ThreadName '示例任务' -Cwd $root -TurnId 'turn-b'
        Equal ($codeA -cmatch '^[A-HJ-NP-Z2-9]{6}$') $true 'Six readable characters'
        Equal ($codeA -cne $codeB) $true 'Same names and forks do not share codes'
        Equal (Get-BridgeReplyCode $taskA -ThreadName '改名后的任务' -TurnId 'turn-new') $codeA 'Rename and new turn retain code'
        Equal (Resolve-BridgeReplyCode $codeA.ToLowerInvariant()).session_id $taskA 'Case-insensitive code lookup'
        $ledgerPath=Join-Path $root 'reply-codes.json'
        $ledger=Read-BridgeJson $ledgerPath -AsHashtable
        Equal $ledger.tasks[$taskA].thread_name '改名后的任务' 'Metadata updated'
        Equal $ledger.tasks[$taskA].cwd $root 'Empty metadata does not clear cwd'
        Equal $ledger.tasks[$taskA].turn_id 'turn-new' 'Metadata tracks latest round'
        $ledger.tasks[$taskA].created_at=[DateTimeOffset]::Now.AddYears(-2).ToString('o')
        Write-BridgeJsonAtomic $ledgerPath $ledger
        Equal (Resolve-BridgeReplyCode $codeA).session_id $taskA 'No time expiry'
        Clear-CodexWeChatNotificationBacklog | Out-Null
        Equal (Get-BridgeReplyCode $taskA) $codeA 'Clear does not erase code bindings'
        Equal @(Get-ChildItem (Join-Path $root 'outbox') -File).Count 0 'Code lookup never replays notifications'
        $catalogPath=Join-Path $root 'thread-catalog.json'
        function Catalog([string]$Name) {
            Write-BridgeJsonAtomic $catalogPath @{refreshed_at=[DateTimeOffset]::Now.ToString('o');threads=@(
                @{session_id=$taskA;name=$Name;cwd=$root;preview=''},@{session_id=$taskB;name='示例任务';cwd=$root;preview=''})}
        }
        Catalog '桌面最新名称'
        Equal (Resolve-BridgeReplyCode $codeA).thread_name '桌面最新名称' 'Name resolved from current catalog by ID'
        Register-BridgeReplyTarget $taskA '旧名称' $root -TurnId 'turn-old' -WeChatMessageId 'exact-a'
        Register-BridgeReplyTarget $taskB '示例任务' $root -TurnId 'turn-b' -WeChatMessageId 'exact-b'
        Equal (Resolve-BridgeReplyTarget -ReferenceMessageIds @('exact-a')).session_id $taskA 'Exact transport ID'
        Equal (Resolve-BridgeReplyTarget -ReferenceText "【已完成】旧名称`n回复码：$codeA").session_id $taskA 'Quoted stable code'
        Equal (Resolve-BridgeReplyTarget -ReferenceText "【已完成】旧名称`n回复码：$codeA" -ReferenceMessageIds @('exact-a')).selection 'quoted_id' 'Exact ID retains historical round'
        Equal (Resolve-BridgeReplyTarget -ReferenceMessageIds @('exact-a','exact-b')).ambiguous $true 'Conflicting IDs rejected'
        Equal (Resolve-BridgeReplyTarget -ReferenceText "回复码：$codeB" -ReferenceMessageIds @('exact-a')).ambiguous $true 'Conflicting ID and code rejected'
        Equal (Resolve-BridgeReplyTarget -ReferenceText '【已完成】示例任务').resolved $false 'Name alone rejected'
        Equal (Resolve-BridgeReplyTarget).resolved $false 'No pending or selected-task fallback'
        $routing=Get-BridgeReplyRoutingState
        $alias=@{wechat_message_id='learned-id';session_id=$taskA;thread_name='旧名称';cwd=$root;turn_id='turn-old';route_alias='wechat_quoted_server_id';notified_at=[DateTimeOffset]::Now.AddHours(-3).ToString('o')}
        $routing.message_targets=@($routing.message_targets)+@($alias)
        Write-BridgeJsonAtomic (Join-Path $root 'reply-routing.json') $routing
        Equal (Resolve-BridgeReplyTarget -ReferenceMessageIds @('learned-id')).resolved $false 'Legacy inferred alias rejected'
        Equal (Resolve-BridgeReplyTarget -ReferenceMessageIds @('unknown-id') -ReferenceCreateTimeMs @([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -InboundMessageId '123456' -InboundCreateTimeMs ([DateTimeOffset]::Now.ToUnixTimeMilliseconds())).resolved $false 'Time cannot authorize a task'

        $script:codeReceipts=[Collections.Generic.List[string]]::new()
        $script:codeSubmissions=[Collections.Generic.List[object]]::new()
        $script:codeBusy=$true
        $script:codeRollout=Join-Path $root 'fixture-rollout.jsonl'
        [IO.File]::WriteAllText($script:codeRollout,'fixture')
        function Get-CodexRolloutPath {param($ThreadId) return $script:codeRollout}
        function Test-CodexThreadIdle {param($RolloutPath) return -not $script:codeBusy}
        function Submit-CodexDesktopPromptToUri {param($Uri,$Prompt,$ThreadId,$ExpectedThreadName,$NavigationDelayMs)
            $script:codeSubmissions.Add(@{id=$ThreadId;name=$ExpectedThreadName;prompt=$Prompt})
            return [pscustomobject]@{window_pid=1;targeting_mode='offline-verified';title_verified=$true}
        }
        function Wait-CodexDesktopTurnStarted {param($RolloutPath,$StartOffset,$SubmitTimeoutSeconds) return [DateTimeOffset]::Now}
        function Send-BridgeText {param($Text,$TimeoutSeconds,[switch]$AllowContextlessRetry) $script:codeReceipts.Add($Text);return [pscustomobject]@{message_id='offline-ack'}}
        function Start-BridgeRelayWorkerProcess {}
        function Invoke-CodexAppServerTurn {throw 'Second writer forbidden'}
        function Refresh-CodexThreadCatalog {throw 'No extra catalog server needed'}
        function Get-CodexThreadRegistry {param($Limit) return @(@{session_id=$taskA;cwd=$root;last_turn_id='turn-new'})}
        function Inbound([string]$Text,[string]$RefText='',[string[]]$RefIds=@()) {
            $path=Join-Path $root ('inbox\'+[guid]::NewGuid().ToString('N')+'.json')
            Write-BridgeJsonAtomic $path @{id=[guid]::NewGuid().ToString('N');create_time_ms=[DateTimeOffset]::Now.ToUnixTimeMilliseconds();received_at=[DateTimeOffset]::Now.ToString('o');relay_state='queued_only';reference_text=$RefText;reference_message_ids=$RefIds;reference_create_time_ms=@()}
            Invoke-BridgeInboundCommand $Text ([pscustomobject]@{path=$path;record=(Read-BridgeJson $path)})
            return $path
        }
        $config=Get-BridgeConfig
        $config.inbound_mode='codex_relay';$config.require_completion_quote=$true;$config.direct_reply_enabled=$false
        $config.relay_enabled_at=[DateTimeOffset]::Now.AddHours(-1).ToString('o')
        Save-BridgeConfig $config
        $path=Inbound "/回复 $codeA 继续测试"
        Equal (Read-BridgeJson $path).target_session_id $taskA 'Explicit code is queued without quote'
        Equal (Read-BridgeJson $path).target_thread_name '桌面最新名称' 'Queue uses current name'
        Equal (Invoke-CodexRelayQueueItem $path).deferred $true 'Busy target stays queued'
        Equal $script:codeSubmissions.Count 0 'Busy target not stolen'
        Catalog '等待时再次改名'
        $script:codeBusy=$false
        Equal (Invoke-CodexRelayQueueItem $path).submitted $true 'Code route submits after idle'
        Equal $script:codeSubmissions[0].id $taskA 'Immutable ID at submission'
        Equal $script:codeSubmissions[0].name '等待时再次改名' 'Rename rechecked at submission'
        Invoke-CodexRelayQueueItem $path | Out-Null
        Equal $script:codeSubmissions.Count 1 'Never replay submitted command'
        $path=Inbound "/回复 $codeA /新建 这只是原任务的输入"
        Equal (Read-BridgeJson $path).command_type 'continue' 'Command text is passed to original task, not reparsed'
        Equal (Read-BridgeJson (Inbound '随便说一句')).relay_state 'not_executed_unquoted' 'Ordinary chat not executed'
        Equal (Read-BridgeJson (Inbound '/回复 BAD')).relay_state 'not_executed_invalid_reply_code' 'Malformed command rejected'
        $unused='AAAAAA';if($unused -in @($codeA,$codeB)){$unused='BBBBBB'}
        Equal (Read-BridgeJson (Inbound "/回复 $unused 内容")).relay_state 'not_executed_unknown_reply_code' 'Unknown code rejected'
        Equal (Read-BridgeJson (Inbound "/回复 $codeA 内容" '' @('exact-b'))).relay_state 'not_executed_conflicting_reply_targets' 'Conflicting explicit selectors not executed'
        Equal (Read-BridgeJson (Inbound '/分支 继续')).relay_state 'not_executed_unquoted' 'Fork still requires quote'
        Equal (Read-BridgeJson (Inbound '/附件' "【已完成】旧名称`n回复码：$codeA")).relay_state 'not_executed_attachment_target_not_found' 'Task code never guesses attachment round'
        $config.relay_max_input_chars=3;Save-BridgeConfig $config
        Equal (Read-BridgeJson (Inbound "/回复 $codeA 超过三个字符")).relay_state 'queued_only' 'Input limit still applies'
        $config.inbound_mode='queue_only';Save-BridgeConfig $config
        Equal (Read-BridgeJson (Inbound "/回复 $codeA 内容")).relay_state 'queued_only' 'Disabled execution remains disabled'
        $config.require_completion_quote=$false;$config.direct_reply_enabled=$true;$config.inbound_mode='codex_relay';Save-BridgeConfig $config
        Equal (Read-BridgeJson (Inbound '继续')).relay_state 'not_executed_quote_target_not_found' 'Legacy permissive settings never infer a task'
        $before=@(Get-ChildItem (Join-Path $root 'outbox') -File).Count
        $list=Get-BridgeReplyCodesText
        Equal ($list.Contains($codeA)) $true 'Codes discoverable for older tasks'
        Equal ($list.Contains('等待时再次改名')) $true 'Listing follows rename'
        Equal @(Get-ChildItem (Join-Path $root 'outbox') -File).Count $before 'Listing does not replay old results'
        $bundle=New-CodexCompletionTextBundle -Name '示例任务' -Summary ('一段完整文字。'*180) -ChunkChars 400 -MaxChunks 10 -ReplyCode $codeA
        Equal (@($bundle.parts).Count -gt 1) $true 'Long result segmented'
        foreach($part in $bundle.parts){Equal ($part.Contains("回复码：$codeA")) $true 'Every segment contains reply code';Equal ($part.Length -le 400) $true 'Code fits message length budget'}

        $healthy=Get-Content -LiteralPath $ledgerPath -Raw -Encoding utf8
        Write-BridgeJsonAtomic $ledgerPath @{schema_version=1;tasks=@{$taskA=@{code=$codeA};$taskB=@{code=$codeA}}}
        Reject {Resolve-BridgeReplyCode $codeA} 'Duplicate code records fail closed'
        Equal (Get-BridgeNotificationReplyCode $taskA) '' 'Damaged optional ledger does not block notification'
        Equal (Read-BridgeJson (Inbound "/回复 $codeA 内容")).relay_state 'not_executed_unknown_reply_code' 'Damaged ledger never queues command'
        [IO.File]::WriteAllText($ledgerPath,$healthy,[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $ledgerPath -Destination ($ledgerPath+'.test-backup')
        Reject {Get-BridgeReplyCode $taskA} 'Missing initialized ledger not silently regenerated'
        Move-Item -LiteralPath ($ledgerPath+'.test-backup') -Destination $ledgerPath
        Equal (Get-BridgeReplyCode $taskA) $codeA 'Restored binding unchanged'
        [pscustomobject]@{assertions=$script:codeAssertions;code=$codeA;id=$taskA}
    }
    Remove-Module $module
    $module=Import-Module $ModulePath -Force -PassThru -DisableNameChecking
    $restored=& $module {param($Id) Get-BridgeReplyCode $Id} $result.id
    if($restored -cne $result.code){throw 'Module restart changed reply code'}
    [pscustomobject]@{passed=$true;assertions=($result.assertions+1);version='0.9.34';network_calls=0;real_desktop_submissions=0;restart_binding_preserved=$true;test_root=$testRoot}|ConvertTo-Json -Compress
}finally{$env:CODEX_WECHAT_BRIDGE_HOME=$oldState;$env:CODEX_HOME=$oldCodex}
