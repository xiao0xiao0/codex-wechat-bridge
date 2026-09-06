# A reply code is a durable task selector, not an authentication credential.
# The inbound transport must still authenticate the paired WeChat user.
function Read-BridgeReplyCodeLedger {
    $root=Initialize-BridgeState
    $path=Join-Path $root 'reply-codes.json'
    $marker=Join-Path $root 'reply-codes.initialized.json'
    if(-not (Test-Path -LiteralPath $path)) {
        if(Test-Path -LiteralPath $marker){throw '回复码记录缺失，已停止重新分配；请恢复本地备份。'}
        return @{schema_version=1;tasks=@{}}
    }
    $ledger=Read-BridgeJson $path -Default $null -AsHashtable
    if($ledger -isnot [Collections.IDictionary] -or $ledger['schema_version'] -ne 1 -or $ledger['tasks'] -isnot [Collections.IDictionary]){throw '回复码记录损坏，未重新分配。'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($item in $ledger.tasks.GetEnumerator()) {
        if($item.Key -notmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$' -or $item.Value -isnot [Collections.IDictionary] -or
            [string]$item.Value['code'] -cnotmatch '^[A-HJ-NP-Z2-9]{6}$' -or -not $seen.Add([string]$item.Value['code'])){throw '回复码记录存在无效或重复绑定，已拒绝使用。'}
    }
    return $ledger
}

function Get-BridgeReplyCode {
    param([Parameter(Mandatory)][string]$SessionId,[string]$ThreadName='',[string]$Cwd='',[string]$TurnId='')
    if($SessionId -notmatch '^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$'){throw '任务身份不是有效的固定 ID，不能分配回复码。'}
    $id=$SessionId.ToLowerInvariant()
    $gate=[Threading.Mutex]::new($false,'Local\CodexWeChatReplyCodes')
    $locked=$false
    try {
        try{$locked=$gate.WaitOne(10000)}catch [Threading.AbandonedMutexException] {$locked=$true}
        if(-not $locked){throw '回复码记录忙，请稍后重试。'}
        $ledger=Read-BridgeReplyCodeLedger
        $changed=$false
        if(-not $ledger.tasks.Contains($id)) {
            $alphabet='ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
            $used=@($ledger.tasks.Values | ForEach-Object { $_['code'] })
            do {$code=-join (1..6 | ForEach-Object {$alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)]})}while($code -in $used)
            $ledger.tasks[$id]=@{code=$code;thread_name=$ThreadName;cwd=$Cwd;turn_id=$TurnId;created_at=[DateTimeOffset]::Now.ToString('o')}
            $changed=$true
        }
        $entry=$ledger.tasks[$id]
        foreach($pair in @(@('thread_name',$ThreadName),@('cwd',$Cwd),@('turn_id',$TurnId))) {
            if($pair[1] -and $entry[$pair[0]] -cne $pair[1]){$entry[$pair[0]]=$pair[1];$changed=$true}
        }
        $root=Initialize-BridgeState
        if($changed){Write-BridgeJsonAtomic (Join-Path $root 'reply-codes.json') $ledger}
        if(-not (Test-Path -LiteralPath (Join-Path $root 'reply-codes.initialized.json'))){Write-BridgeJsonAtomic (Join-Path $root 'reply-codes.initialized.json') @{schema_version=1;initialized_at=[DateTimeOffset]::Now.ToString('o')}}
        return [string]$entry['code']
    }finally{if($locked){$gate.ReleaseMutex()};$gate.Dispose()}
}

function Get-BridgeNotificationReplyCode {
    param([string]$SessionId,[string]$ThreadName='',[string]$Cwd='',[string]$TurnId='')
    try { return Get-BridgeReplyCode -SessionId $SessionId -ThreadName $ThreadName -Cwd $Cwd -TurnId $TurnId }
    catch {
        # Never lose an otherwise valid completion or resend already delivered
        # text because the optional selector ledger needs recovery.
        Write-BridgeLog -Level WARN -Message ('Reply code unavailable; notification remains deliverable without a code: '+$_.Exception.Message)
        return ''
    }
}

function Resolve-BridgeReplyCode {
    param([Parameter(Mandatory)][string]$Code)
    $normalized=$Code.Trim().ToUpperInvariant()
    $unknown=[pscustomobject]@{resolved=$false;ambiguous=$false;quote_not_found=$true;pending_count=0;selection='unknown_reply_code'}
    if($normalized -cnotmatch '^[A-HJ-NP-Z2-9]{6}$'){return $unknown}
    $ledger=Read-BridgeReplyCodeLedger
    $found=@($ledger.tasks.GetEnumerator() | Where-Object { $_.Value['code'] -ceq $normalized })
    if($found.Count -ne 1){return $unknown}
    $item=$found[0]
    $name=Get-CodexThreadDisplayName -SessionId ([string]$item.Key) -Cwd ([string]$item.Value['cwd']) -FallbackName ([string]$item.Value['thread_name'])
    return [pscustomobject]@{resolved=$true;ambiguous=$false;selection='reply_code';session_id=[string]$item.Key;thread_name=$name;cwd=[string]$item.Value['cwd'];turn_id=[string]$item.Value['turn_id'];reply_code=$normalized}
}

function Resolve-BridgeExactReplyTarget {
    param([string]$ReferenceText,[string[]]$ReferenceMessageIds=@())
    $state=Get-BridgeReplyRoutingState
    $targets=[Collections.Generic.List[object]]::new()
    foreach($id in $ReferenceMessageIds) {
        if(-not $id){continue}
        foreach($target in @($state.message_targets)) {
            # Old server aliases were learned by time inference and are not proof.
            if((Test-BridgeProperty $target 'route_alias') -and $target.route_alias){continue}
            if([string]$target.wechat_message_id -ceq $id){$targets.Add($target)}
        }
    }
    $selection='quoted_id'
    $codeMatches=@([regex]::Matches($ReferenceText,'(?im)^回复码[：:]\s*([A-HJ-NP-Z2-9]{6})\s*$'))
    foreach($match in $codeMatches) {
        $route=Resolve-BridgeReplyCode $match.Groups[1].Value
        if(-not $route.resolved){return $route}
        $targets.Add($route)
        $selection='quoted_code'
    }
    $ids=@($targets | ForEach-Object {[string]$_.session_id} | Sort-Object -Unique)
    if($ids.Count -ne 1){return [pscustomobject]@{resolved=$false;ambiguous=($ids.Count -gt 1);quote_not_found=$true;pending_count=$ids.Count;names=@();selection='unverified_quote'}}
    # Do not let an exact item id silently point to two completion rounds when
    # an attachment command depends on the quoted round, not just the task.
    $exactTargets=@($targets | Where-Object { -not (Test-BridgeProperty $_ 'reply_code') })
    $turns=@($exactTargets | ForEach-Object {[string]$_.turn_id} | Sort-Object -Unique)
    if($turns.Count -gt 1){return [pscustomobject]@{resolved=$false;ambiguous=$true;pending_count=1;names=@();selection='conflicting_quote_rounds'}}
    $target=if($exactTargets.Count){$selection='quoted_id';$exactTargets[0]}else{$targets[0]}
    return [pscustomobject]@{resolved=$true;ambiguous=$false;selection=$selection;session_id=$ids[0];thread_name=(Get-CodexThreadDisplayName -SessionId $ids[0] -Cwd ([string]$target.cwd) -FallbackName ([string]$target.thread_name));cwd=[string]$target.cwd;turn_id=[string]$target.turn_id}
}

function Get-BridgeReplyCodesText {
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add('【任务回复码】')
    foreach($record in @(Get-CodexThreadRegistry -Limit 30)) {
        try {
            $id=Resolve-CodexQuotedSessionId -SessionId ([string]$record.session_id)
            $name=Get-CodexThreadDisplayName -SessionId $id -Cwd ([string]$record.cwd)
            $code=Get-BridgeReplyCode -SessionId $id -ThreadName $name -Cwd ([string]$record.cwd) -TurnId ([string]$record.last_turn_id)
            $lines.Add("$code  $name")
        }catch{Write-BridgeLog -Level WARN -Message ('Reply code listing skipped an unverified task: '+$_.Exception.Message)}
    }
    if($lines.Count -eq 1){$lines.Add('暂无可核实的任务；请先在 Codex 完成一轮对话。')}
    $lines.Add('发送 /回复 回复码 任务内容。回复码固定绑定任务，改名后仍有效。')
    return $lines -join "`n"
}
