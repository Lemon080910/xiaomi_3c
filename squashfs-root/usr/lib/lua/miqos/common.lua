#!/usr/bin/lua
-- fixed global cfg and variables

local fs = require "nixio.fs"
local ubus = require "ubus"
local uci=  require 'luci.model.uci'
util = require 'luci.util'
px =  require "posix"
local nixio=require 'nixio'

local cfg_dir='/etc/config/'
local tmp_cfg_dir='/tmp/etc/config/'
local cfg_file=cfg_dir .. 'miqos'
local tmp_cfg_file=tmp_cfg_dir .. 'miqos'

-- 配置
cfg={
    server={path='/var/run/miqosd.sock'},
    idle_timeout={wire=301,wireless=10},
    check_interval=20,  -- 20s检测一次
    lan={ip='',mask=''},
    DEVS={          --在对应设备上做QoS
        UP={dev='',id='2',},
        DOWN={dev='ifb0',id='1',},
    },
    guest={changed=0,UP=0.6,DOWN=0.6,inner={UP=0,DOWN=0},default=0.6},
    xq={changed=0,UP=0.90,DOWN=0.90,inner={UP=0,DOWN=0},default=0.9},
    enabled={started=true,changed=false,flag=false},
    group={changed=false,tab=g_group_def,default='00',min_default=0.5},
    flow={changed=false,seq='',dft='auto'},
    qdisc={old=nil,cur=nil},
    bands={UP=0,DOWN=0,changed=true},
    qos_type={changed=false,mode='service'},
    quan=1600,
    virtual_proto='ip',
    supress_host={changed=false,enabled=false},
}

seq_prio={
    auto  ={game=2,web=3,video=4,download=5},
    game  ={game=2,web=3,video=4,download=5},
    web   ={web=2,game=3,video=4,download=5},
    video ={video=2,game=3,web=4,download=5},
}

UNIT="kbit"
UP,DOWN='UP','DOWN'
const_ipt_mangle = 'iptables -t mangle '
const_ipt_clear = 'iptables -t mangle -F '
const_ipt_delete='iptables -t mangle -X '
const_tc_qdisc='tc qdisc'
const_tc_class='tc class'
const_tc_filter='tc filter'

-- qdisc规则,用于保持qdisc的规则处理
qdisc={}
-- 全局qdisc
old_qdisc,cur_qdisc = '',''

g_debug=false
g_CONFIG_HZ=100  -- HZ用来计算buffer量大小
g_htb_buffer_factor=1.5
g_htb_buffer_data=1024/8.0/g_CONFIG_HZ
g_min_burst=1600

g_supress_host=false

--logger
px.openlog('miqos','np',LOG_USER)
function logger(loglevel,msg)
    -- print(msg)
    px.syslog(loglevel,msg)
end

const_lockfile="/tmp/miqos.lock"
g_lockfile=nil

-- only read 1st line reponse.
function run_cmd(cmd)
    if not cmd or cmd == "" then
        return nil
    end
    local t=io.popen(cmd)
    local a=t:read("*line")
    t:close()
    return a
end

function read_interfaces(net)
    local tbl={}
    if net == "lan" then
        return "ifb0"
    elseif net == "wan" then
        local wan=run_cmd("uci -q get network.wan.ifname")
        return wan
    end
    return ""
end

function lock()
    if not g_lockfile then
        g_lockfile = nixio.open(const_lockfile,'w')
    end

    if not g_lockfile:lock("tlock") then
        logger(3, 'Note: try to get lock failed .')
        return false
    end

    return true
end

function unlock()
    if g_lockfile then
        g_lockfile:lock("ulock")
        g_lockfile:close()
        g_lockfile=nil
    end
    return true
end

g_ubus = ubus.connect()

-- 读取cfg到tmp的meory文件夹中
function cfg2tmp()
    if QOS_VER == 'FIX' then
        return true
    end
    local r1,r2,r3 = fs.mkdirr(tmp_cfg_dir)
    if not r1 then
        logger(3, 'fatal error: mkdir failed, code:' .. r2 .. ',msg:'..r3)
        return nil
    end

    r1,r2,r3 = fs.copy(cfg_file,tmp_cfg_file)
    if not r1 then
        logger(3,'fatal error: copy cfg file 2 /tmp memory failed. code:' .. r2 .. ',msg:'..r3)
        return nil
    end
    return true
end

-- 十进制转十六进制
function dec2hexstr(d)
    return string.format("%x",d)
end

-- 拷贝最新配置到memory中
function tmp2cfg()
    if QOS_VER == 'FIX' then
        return true
    end
    if not fs.copy(tmp_cfg_file,cfg_file) then
        logger(3,'fatal error: copy /tmp cfg file 2 /etc/config/ failed. exit.')
        return nil
    end
    return true
end

-- 深拷贝table
function copytab(st)
    local tab={}
    for k,v in pairs(st or {}) do
        if type(v) ~= 'table' then tab[k]=v
        else tab[k]=copytab(v) end
    end
    return tab
end

-- 从标准config中读取配置,(可能没用了)
function get_conf_std(conf,type,opt,default)
    local x=uci.cursor()
    local _,e = pcall(function() return x:get(conf,type,opt) end)
    return e or default
end

function get_cursor()
    local cursor = uci.cursor()
    if QOS_VER ~= 'FIX' then
        cursor:set_confdir(tmp_cfg_dir)
    end
    return cursor
end

-- 从缓存config中读取配置
function get_tbls(conf,type)
    local tbls={}
    local cursor = get_cursor()
    local _,e = pcall(function() cursor:foreach(conf, type, function(s) tbls[s['name']]=s end) end)
    return tbls or {}
end

-- 读取Lan的ip和mask
local function get_network(netname)
   local ret = g_ubus:call("network.interface", "status", {interface=netname})
   if ret and table.getn(ret['ipv4-address']) > 0 then
       local addr = table.remove(ret['ipv4-address'])
       return addr.address, addr.mask
   end
   return nil
end

-- 读取网络配置, 在QoS on/off情况下也需要调用
function read_network_conf()

    -- 获取lan ip和mask
    cfg.lan.ip,cfg.lan.mask = get_network('lan')

    if QOS_VER == "HWQOS" then
        return true
    end
    local tmp = get_conf_std('network','wan','proto')
    if QOS_VER == 'STD' then
        if tmp == 'dhcp' or tmp == 'static' then
            cfg.DEVS.UP.dev = read_interfaces("wan")
            cfg.virtual_proto='ip'
        elseif tmp == 'pppoe' then
            cfg.DEVS.UP.dev = read_interfaces("wan")       -- 上行限速均在wan接口上做
            cfg.virtual_proto='pppoe'
        else
            logger(1, 'cannot determine wan interface! exit')
            return false
        end
    else
        -- keep default cfg for QOS-TYPE=ctf
        if tmp == 'pppoe' then
            cfg.DEVS.UP.dev= read_interfaces("wan")
            cfg.virtual_proto='pppoe'
        else
            cfg.DEVS.UP.dev= read_interfaces("wan")
            cfg.virtual_proto='ip'
        end

    end

    -- 检测设备是否已经UP,否则直接退出
    for _,_dev in pairs(cfg.DEVS) do
        local ret=util.exec('ip link 2>&-|grep UP|grep ' .. _dev.dev)
        if ret == '' then
            logger(3,'DEV '.._dev.dev .. ' is not UP. exit. ')
            return false
        end
    end

    return true
end


-- 更新读取相关配置文件
-- 1. 读取全局性配置
-- 2.调用对应的模块的配置处理逻辑
function read_qos_config()
    -- qos处于shutdown状态
    if QOS_VER ~= 'FIX' and not cfg.enabled.started then
        if g_debug then logger(3, 'qos stopped, no action.') end
        return false
    end

    local tmp_str1,tmp_str2
    local setting_tbl = get_tbls('miqos','miqos')

    --qos开关
    tmp_str1= setting_tbl['settings']['enabled'] or '0'
    if cfg.enabled.flag ~= tmp_str1 then
        cfg.enabled.flag = tmp_str1
        cfg.enabled.changed = true
    end

    -- qos type 模式改变
    tmp_str1=setting_tbl['settings']['qos_auto'] or 'auto'
    if cfg.qos_type.mode ~= tmp_str1 then
        cfg.qos_type.mode = tmp_str1    -- 更新qos当前的模式
        cfg.qos_type.changed=true
    else
        cfg.qos_type.changed=false
    end

    -- 读取service确认服务优先级
    local system_tbl=get_tbls('miqos','system')
    local tmp_str1=system_tbl['param']['seq_prio'] or 'auto'
    if cfg.flow.seq ~= tmp_str1 then
        cfg.flow.seq = tmp_str1
        if cfg.flow.seq == '' then
            cfg.flow.seq = cfg.flow.dft
        end

        -- pr(cfg.flow)
        cfg.flow.changed=true
    end

    -- 确定当前的带宽
    tmp_str1=setting_tbl['settings']['upload'] or '0'
    tmp_str2=setting_tbl['settings']['download'] or '0'
    if cfg.bands.UP ~= tmp_str1 or cfg.bands.DOWN ~= tmp_str2 then
        cfg.bands.UP,cfg.bands.DOWN = tmp_str1,tmp_str2
        cfg.bands.changed=true
    else
        cfg.bands.changed=false
    end

    -- 未测带宽，则清除规则，退出
    if tonumber(cfg.bands.UP) <=0 or tonumber(cfg.bands.DOWN) <= 0 then
        cleanup_system()
        return false
    end

    -- 确定当前模式
    if QOS_VER == 'HWQOS' then
        cfg.qdisc.cur='service'
    elseif cfg.enabled.flag == '0' then     -- qos off
        cfg.qdisc.cur='prio'
    elseif cfg.qos_type.mode == 'service' then
        cfg.qdisc.cur='service'
    else
        cfg.qdisc.cur='host'
    end

    -- 更新全局的qdisc
    if QOS_VER == 'FIX' then
        cur_qdisc='service'
        cfg.qdisc.cur='service'
    else
        old_qdisc,cur_qdisc = cfg.qdisc.old,cfg.qdisc.cur
    end

    -- call对应的模式的配置读取逻辑
    if qdisc[cur_qdisc] and qdisc[cur_qdisc].read_qos_config then
        qdisc[cur_qdisc].read_qos_config()
    end

    return true
end

-- 读取更新group配置
function read_qos_group_config()
    g_group_def=get_tbls('miqos','group')
    -- QOS_TYPE: auto 最小保证和最大带宽设置均无效， min 最小保证设置有效， max 最大带宽设置有效, both 最大最小均可调整
    -- 自动模式设置组为group 00
    g_group_def[cfg.group.default]['min_grp_uplink']=cfg.group.min_default
    g_group_def[cfg.group.default]['min_grp_downlink']=cfg.group.min_default
    if QOS_VER == 'FIX' or QOS_VER == 'HWQOS' then
        -- 如果用户配置了limit_flag=off,则读取的max限速不生效
        for k,v in pairs(g_group_def) do
            if v['name'] ~= cfg.group.default then
                if not v.flag then
                    if tonumber(g_group_def[k]['max_grp_uplink'] or 0) <= 0 and tonumber(g_group_def[k]['max_grp_downlink'] or 0) <= 0 then
                        g_group_def[k]['flag'] = 'off'
                    end
                elseif v.flag == 'off' then
                    g_group_def[k]['max_grp_uplink'] = 0
                    g_group_def[k]['max_grp_downlink'] = 0
                end
            end
        end
        return true
    elseif cfg.qos_type.mode == 'auto' then
        for k,v in pairs(g_group_def) do
            if v['name'] ~= cfg.group.default then
                g_group_def[k] = nil
            else
                g_group_def[k]['min_grp_uplink']=cfg.group.min_default
                g_group_def[k]['min_grp_downlink']=cfg.group.min_default
            end
        end
    elseif cfg.qos_type.mode == 'min' then
        for k,v in pairs(g_group_def) do
            if v['name'] ~= cfg.group.default then
                g_group_def[k]['max_grp_uplink'] = 0
                g_group_def[k]['max_grp_downlink'] = 0
            end
            if g_group_def[k]['min_grp_uplink'] == 0 then
                g_group_def[k]['min_grp_uplink'] = cfg.group.min_default
            end
            if g_group_def[k]['min_grp_downlink'] == 0 then
                g_group_def[k]['min_grp_downlink'] = cfg.group.min_default
            end
        end
    elseif cfg.qos_type.mode == 'max' then
        for k,v in pairs(g_group_def) do
            if v['name'] ~= cfg.group.default then
                g_group_def[k]['min_grp_uplink'] = 0
                g_group_def[k]['min_grp_downlink'] = 0
            end
            if g_group_def[k]['min_grp_uplink'] == 0 then
                g_group_def[k]['min_grp_uplink'] = cfg.group.min_default
            end
            if g_group_def[k]['min_grp_downlink'] == 0 then
                g_group_def[k]['min_grp_downlink'] = cfg.group.min_default
            end
        end
    elseif cfg.qos_type.mode == 'both' then
        -- keep config for both changes.
    elseif cfg.qos_type.mode == 'service' then
        -- 如果用户配置了limit_flag=off,则读取的max限速不生效
        for k,v in pairs(g_group_def) do
            if v['name'] ~= cfg.group.default then
                if not v.flag then
                    if tonumber(g_group_def[k]['max_grp_uplink'] or 0) <= 0 and tonumber(g_group_def[k]['max_grp_downlink'] or 0) <= 0 then
                        g_group_def[k]['flag'] = 'off'
                    end
                elseif v.flag == 'off' then
                    g_group_def[k]['max_grp_uplink'] = 0
                    g_group_def[k]['max_grp_downlink'] = 0
                end
            end
        end
    else
        logger(3,'ERROR: not supported qos type MODE.')
        return false
    end
    return true
end

-- 读取更新guest+xq配置
function read_qos_guest_xq_config(reset)
    local ids={"guest","xq"}
    if reset then
        for _,id in pairs(ids) do
            for _,dir in pairs({'UP','DOWN'}) do
                local inner=tonumber(cfg[id].default)
                if inner <= 0 then
                    cfg[id][dir] = tonumber(cfg.bands[dir])
                elseif inner <= 1 then
                    cfg[id][dir] = math.ceil(cfg.bands[dir] * inner )
                else
                    cfg[id][dir] = math.ceil(inner)
                end
            end
        end
        return true
    end

    local ids_tbl=get_tbls('miqos','limit')
    for _,id in pairs(ids) do
        if ids_tbl[id] then
            -- 参数变化
            local tmp_str1,tmp_str2=ids_tbl[id]['up_per'], ids_tbl[id]['down_per']
            --如果未设置,则去默认值, 设置为0,表示不限速
            if not tmp_str1 then tmp_str1 = cfg[id].default end
            if not tmp_str2 then tmp_str2 = cfg[id].default end

            if cfg[id].inner.UP ~= tmp_str1 or cfg[id].inner.DOWN ~= tmp_str2 then
                cfg[id].inner.UP,cfg[id].inner.DOWN=tmp_str1,tmp_str2

                cfg[id].changed=1
            else
                cfg[id].changed=0
            end

            for _,dir in pairs({'UP','DOWN'}) do
                local inner=tonumber(cfg[id].inner[dir])
                if inner <= 0 then
                    cfg[id][dir] = tonumber(cfg.bands[dir])
                elseif inner <= 1 then
                    cfg[id][dir] = math.ceil(cfg.bands[dir] * inner )
                else
                    cfg[id][dir] = math.ceil(inner)
                end
            end
        end
    end

    return true
end

function get_burst(ceil)
    local buffer = math.ceil(ceil*g_htb_buffer_data*g_htb_buffer_factor)
    local cbuffer = math.ceil(ceil*g_htb_buffer_data)

    if buffer < g_min_burst then
        buffer = g_min_burst
    end
    if cbuffer < g_min_burst then
        cbuffer = g_min_burst
    end

    return buffer,cbuffer
end

function get_supressed_ceil(ceil, supress_value)
    local real_lceil = ceil
    if cfg.supress_host.enabled and supress_value and supress_value > 0 then
        local supress=math.ceil(ceil*0.75)
        if supress > supress_value then
            supress = supress_value
        end
        real_lceil = real_lceil - supress
    end
    return real_lceil
end

-- 无输出执行命令
function exec_cmd(tblist, ignore_error)
    local outlog ='/tmp/miqos.log'
    for _,v in pairs(tblist) do
        local cmd = v

        if g_debug then
            logger(3, '++' .. cmd)
            cmd = cmd .. ' >/dev/null 2>>' .. outlog
        else
            cmd = cmd .. " &>/dev/null "
        end

        if os.execute(cmd) ~= 0 and ignore_error ~= 1 then
            if g_debug then
                os.execute('echo "^^^ '.. cmd .. ' ^^^ " >>' .. outlog)
            end
            logger(3, '[ERROR]:  ' .. cmd .. ' failed!')
            dump_qdisc(cfg.DEVS)

            -- 出错，则退出系统
            system_exit()
            return false
        end
    end

    return true
end

-- 集合数据结构
function newset()
    local reverse = {}
    local set = {}
    return setmetatable(set, {__index = {
        insert = function(set, value)
            if not reverse[value] then
                table.insert(set, value)
                reverse[value] = table.getn(set)
            end
        end,
        remove = function(set, value)
            local index = reverse[value]
            if index then
                reverse[value] = nil
                local top = table.remove(set)
                if top ~= value then
                    reverse[top] = index
                    set[index] = top
                end
            end
        end
    }})
end

--split string with chars '$p'
string.split = function(s, p)
    local rt= {}
    string.gsub(s, '[^'..p..']+', function(w) table.insert(rt, w) end )
    return rt
end

local function print_r(root,ind,printf)
    local indent="    " .. ind
    if not printf then printf = logger end

    for k,v in pairs(root or {}) do
            if(type(v) == "table") then
                    printf(3,indent .. k .. " = {")
                    print_r(v,indent,printf)
                    printf(3, indent .. "}")
            elseif(type(v) == "boolean") then
                local tmp = 'false'
                if v then tmp = 'true' end
                printf(3, indent .. k .. '=' .. tmp)
            else
                printf(3, indent .. k .. "=" .. v)
            end
    end
end

function pr(root, mark, printf)
    if not printf then printf = logger end
    if not mark then
        mark = ''
    end
    mark = mark .. '-----------------'
    printf(3,mark)
    print_r(root,'')
    printf(3,mark)
end

function pr_console(root, mark)
    if not printf then printf = logger end
    if not mark then
        mark = ''
    end
    mark = mark .. '-----------------'
    printf(3,mark)
    print_r(root,'',printf)
    printf(3,mark)
end

function p_sysinfo()
    local tmp='INFO,' .. 'Qdisc:' .. (cfg.qdisc.cur or '') .. ',Mode:' .. cfg.qos_type.mode .. ',Band: U:'.. cfg.bands.UP .. 'kbps,D:' .. cfg.bands.DOWN .. 'kbps'
    return tmp;
end


g_limit={}
-- 更新对应qdisc的更新counter
-- g_limit用于命令返回的data
function update_counters(devs)
    -- logger(3,'---update counters-----.')

    local cur_qdisc = cfg.qdisc.cur
    if qdisc[cur_qdisc] and qdisc[cur_qdisc].update_counters then
        g_limit = qdisc[cur_qdisc].update_counters(devs)
    else
        g_limit = {}
    end
end

local cmd_dump_qdisc='tc -d qdisc show | sort '
local cmd_show_class='tc -d class show dev '
local cmd_show_filter='tc -d filter show dev '
-- 出错后dump规则用于除错
function dump_qdisc(devs)
    local tblist={}
    table.insert(tblist,cmd_dump_qdisc)

    for _,dev in pairs(devs) do
        table.insert(tblist,  cmd_show_class .. dev.dev .. ' | sort ')
    end
    for _,dev in pairs(devs) do
        table.insert(tblist,  cmd_show_filter .. dev.dev)
    end
    logger(3, '--------------miqos error dump START--------------------')
    local pp,data
    for _,cmd in pairs(tblist) do
        pp=io.popen(cmd)
        if pp then
            for d in pp:lines() do
                logger(3, d)
            end
        end
    end
    pp:close()
    logger(3, '--------------miqos error dump END--------------------')
end

--根据带宽计算codel的target和interval参数,单位us
function calc_fq_codel_params(band)
    local _target,_interval=5000,100000

    if band <= 0 then
        return _target,_interval
    end

    -- target, 单位us
    _target = 1000*1000*1600*8/1000/band
    if _target < 5000 then
        _target = 5000
    end

    -- interval, 单位us
    _interval = (100 - 5) * 1000 + _target

    return math.ceil(_target),math.ceil(_interval)
end
--
function apply_leaf_qdisc(tblist,dev,flow_id,parent_cid,ceil, is_new)
    local tmp_act='add'
    local expr
    local tmp_tblist={}
    if g_leaf_type == 'sfq' then
        -- sfq leaf
        if not is_new then
            expr = string.format(" %s del dev %s parent %s:%s sfq", const_tc_qdisc, dev, flow_id, parent_cid)
            table.insert(tmp_tblist, expr)
        end

        expr = string.format(" %s %s dev %s parent %s:%s sfq perturb 10 ", const_tc_qdisc, tmp_act, dev, flow_id, parent_cid)
        table.insert(tblist, expr)
    elseif g_leaf_type == 'fq_codel' then
        -- fq_codel
        if not is_new then
            expr = string.format(" %s del dev %s parent %s:%s ", const_tc_qdisc, dev, flow_id, parent_cid)
            table.insert(tmp_tblist, expr)
        end

        local target,interval=calc_fq_codel_params(ceil)

        expr = string.format(" %s %s dev %s parent %s:%s fq_codel limit 1024 flows 1024 target %sus interval %sus ",
            const_tc_qdisc, tmp_act, dev, flow_id, parent_cid, target, interval)
        table.insert(tblist, expr)
    else
        -- pfifo as default
        if not is_new then
            expr = string.format(" %s del dev %s parent %s:%s ", const_tc_qdisc, dev, flow_id, parent_cid)
            table.insert(tmp_tblist, expr)
        end

        expr = string.format(" %s %s dev %s parent %s:%s pfifo limit 1024 ",
            const_tc_qdisc, tmp_act, dev, flow_id, parent_cid)
        table.insert(tblist, expr)
    end

    exec_cmd(tmp_tblist,1)

end

-- 保持ppp的Link Control Protocol/Network Control Protocol不限速
function apply_ppp_qdisc(tblist, dev, flow_id, prio)
    local fprio = prio or '1'
    local mask = '0x80'
    local offset=0
    local proto_id
    if cfg.virtual_proto == 'pppoe' then
        offset=6
        proto_id='0x8864'
        expr=string.format(" %s %s dev %s parent %s: prio %s protocol %s u32 match u8 0x80 %s at %d flowid %s: ",
                    const_tc_filter, 'add', dev, flow_id, fprio, proto_id, mask, offset, flow_id)
        table.insert(tblist,expr)
    end
end

-- 特殊的流，arp，<64kb的小包优先, 都走到flow_id:prio_class_id
function apply_arp_small_filter(tblist, dev, act, flow_id, prio_class_id)
    local expr=''
    local proto_id,offset,fprio='ip',0,'3'

    -- pppoe以外，所有协议均为ip
    if cfg.virtual_proto == 'pppoe' then
        if dev == 'pppoe-wan' then      -- R1CM的pppoe-wan上行是IP包
            offset=0
        elseif string.find(dev,"eth",1) then     -- R1D/R2D的wan上行包是ppp-sess包
            offset=8
            proto_id='0x8864'
        else -- ifb0, for ctf, it's ip, for std, it' pppoe-wan,only DOWN
            if QOS_VER == 'STD' then    -- R1CM的ifb下行，是pppoe-sess包
                proto_id='0x8864'
                offset=8
            else
                proto_id='ip'   -- R1D/R2D的ifb下行，是IP包
                offset=0
            end
        end
    end

    -- ARP
    --[[
    expr=string.format(" %s %s dev %s parent %s: prio %s protocol arp u32 match u8 0x00 0x00 at 0 flowid %s:%s ",
                    const_tc_filter, act, dev, flow_id, fprio, flow_id, prio_class_id)
    table.insert(tblist,expr)
    --]]

    -- 小包 <64 kbytes, 会包含TCP的SYN/EST/FIN/RST
    local mask = '0xffc0'
    expr=string.format(" %s %s dev %s parent %s: prio %s protocol %s u32 match u16 0x0000 %s at %d flowid %s:%s ",
                    const_tc_filter, act, dev, flow_id, fprio, proto_id, mask, offset + 2, flow_id,  prio_class_id)
    table.insert(tblist,expr)

end

-- 根据interface类型不同，返回stab参数的string
-- Note：因为路由器现在只支持ethernet，不需要类似ATM的分packet，就不需要mpu来做映射
-- 只需要增加每个packet的overhead即可保证限速的精确性
-- Overhead: pppoe, 22; ether, 14
function get_stab_string(dev)
    if g_enable_stab then
        local overhead='0'
        if cfg.virtual_proto == 'pppoe' then
            if dev == 'pppoe-wan' then
                overhead = '14'
            elseif string.find(dev,"eth") then
                overhead = '22'
            else
                if QOS_VER == 'STD' then
                    overhead = '22'
                else
                    overhead = '14'
                end
            end
        else
            overhead = '14'
        end

        return 'stab linklayer ethernet mpu 0 overhead ' .. overhead
    else
        return ' '
    end
end

local function clear_default()
    local expr,tblist='',{}
    for _,dev in pairs({'ifb0','eth0.2','eth0','eth1','br-lan','pppoe-wan'}) do
        expr = string.format("%s del dev %s root ", const_tc_qdisc, dev)
        table.insert(tblist,expr)
    end

    if not exec_cmd(tblist,1) then
        logger(3, 'clean qdisc rules for dataflow mode failed!')
    end
end

-- 清除规则
function cleanup_system()
    if QOS_VER ~= 'FIX' and cfg.qdisc.cur and qdisc[cfg.qdisc.cur] and qdisc[cfg.qdisc.cur].clean then
        logger(3,'======= Cleanup QoS rules for ' .. cfg.qdisc.cur)
        qdisc[cfg.qdisc.cur].clean(cfg.DEVS)
        cfg.qdisc.cur=nil
        cfg.qdisc.old=nil   -- 清除当前生效的qdisc
    else
        if QOS_VER == "HWQOS" then
            qdisc["service"].clean(nil)
        else
            clear_default()     -- 因为未知，所以清除所有规则
        end
    end

    return true
end



