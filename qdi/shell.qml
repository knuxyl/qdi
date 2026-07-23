import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Dialogs
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Qt.labs.folderlistmodel
import Quickshell.Widgets
import QtCore

ShellRoot {
    id: root
    property string draggingFile: ""
    property point dragOffset: Qt.point(0,0)
    property point currentDragGlobal: Qt.point(0,0)
    property var dragPreviewPositions: ({})
    property var selectedFiles: []
    property bool settingsVisible: false
    property int settingsWinX: 200
    property int settingsWinY: 200
    property bool bgContextMenuVisible: false
    property point bgContextMenuGlobalPos: Qt.point(0,0)
    property string bgContextMenuScreen: ""
    property bool iconContextMenuVisible: false
    property var iconContextMenuFiles: []
    property point iconContextMenuGlobalPos: Qt.point(0,0)
    property string iconContextMenuScreen: ""
    function hideAllMenus() { bgContextMenuVisible = false; iconContextMenuVisible = false }
    function showBgContextMenuAt(screenName, globalPos) { bgContextMenuScreen = screenName; bgContextMenuGlobalPos = globalPos; bgContextMenuVisible = true; iconContextMenuVisible = false; checkSystemClipboard() }
    function showIconContextMenuAt(screenName, files, globalPos) { iconContextMenuScreen = screenName; iconContextMenuFiles = files.slice(); iconContextMenuGlobalPos = globalPos; iconContextMenuVisible = true; bgContextMenuVisible = false }

    property string defaultDesktopPath: {
        var p = StandardPaths.writableLocation(StandardPaths.DesktopLocation)
        var s = p ? p.toString() : ""
        if (s.startsWith("file://")) s = s.replace("file://","")
        return s
    }
    property string desktopPath: (appSettings.desktopFolderPath && appSettings.desktopFolderPath.length>0) ? appSettings.desktopFolderPath : defaultDesktopPath
    property url desktopUrl: "file://" + desktopPath
    property string _prevDesktopPath: ""
    property var _sortedScreens: []
    property var _cachedGrid: []
    property var _cachedGridSet: ({})
    property var _primaryGrid: []
    property var _primaryGridSet: ({})
    property point selGlobalStart: Qt.point(0,0)
    property point selGlobalEnd: Qt.point(0,0)
    property point lastMouseGlobal: Qt.point(0,0)
    property bool selActive: false
    property var dragGroupOffsets: ({})
    property var sortDisplayNames: ["Name A-Z", "Name Z-A", "Type", "Size", "Date Modified"]
    property var sortValues: ["nameAsc", "nameDesc", "type", "size", "modified"]
    property var sortCapitalizationDisplay: ["Ignore", "Capitalized", "Lowercase"]
    property var sortCapitalizationValues: ["ignore", "capitalized", "lowercase"]
    signal posChanged(string name, point pos)

    function copyObj(o){ var r={}; if(o) for(var k in o) r[k]=o[k]; return r }
    function copyArr(a){ var r=[]; if(a) for(var i=0;i<a.length;i++) r.push(a[i]); return r }

    onDesktopPathChanged: {
        if (_prevDesktopPath!=="" && _prevDesktopPath!==desktopPath){
            var byPos = copyObj(appSettings.positionsByFolder)
            var byZ = copyObj(appSettings.zOrderByFolder)
            byPos[_prevDesktopPath] = copyObj(appSettings.positions)
            byZ[_prevDesktopPath] = copyArr(appSettings.zOrder)
            appSettings.positionsByFolder = byPos
            appSettings.zOrderByFolder = byZ
            var newPos = byPos[desktopPath]
            var newZ = byZ[desktopPath]
            if (newPos) appSettings.positions = copyObj(newPos); else appSettings.positions = {}
            if (newZ) appSettings.zOrder = copyArr(newZ); else appSettings.zOrder = []
            rebuildCache(); refreshAllPositions(); saveTimer.restart()
            desktopWatcher.running = false; desktopWatcher.running = true; desktopChangeDebounce.restart()
        }
        _prevDesktopPath = desktopPath
    }
    function toRgba(hex,a){ var r=0.2; var g=0.5; var b=1; if (hex&&hex.length===7){ r=parseInt(hex.substr(1,2),16)/255; g=parseInt(hex.substr(3,2),16)/255; b=parseInt(hex.substr(5,2),16)/255 } return Qt.rgba(r,g,b,a) }
    function primaryScreen(){ if (_sortedScreens.length===0) return null; if (appSettings.primaryMonitor && appSettings.primaryMonitor.length>0){ for (var sc of _sortedScreens) if (sc.name===appSettings.primaryMonitor) return sc } return _sortedScreens[0] }
    function screenByName(name){ for (var sc of _sortedScreens) if (sc.name===name) return sc; return null }
    function screenForPoint(x,y){ for (var sc of _sortedScreens) { if (x>=sc.x && x<sc.x+sc.width && y>=sc.y && y<sc.y+sc.height) return sc } var best=null; var bestD=1e12; for (var sc of _sortedScreens){ var dx=Math.max(0, Math.max(sc.x-x, x-(sc.x+sc.width))); var dy=Math.max(0, Math.max(sc.y-y, y-(sc.y+sc.height))); var d=dx*dx+dy*dy; if (d<bestD){ bestD=d; best=sc } } return best?best:_sortedScreens[0] }
    function iconPxFor(sc){ if (!sc) return 52; return Math.max(12, Math.round(sc.height * appSettings.iconSizePct / 100)) }
    function fontPxFor(sc){ if (!sc) return 11; return Math.max(6, Math.round(sc.height * appSettings.fontSizePct / 100)) }
    function marginTopPxFor(sc){ return Math.round(sc.height * appSettings.marginTopPct / 100) }
    function marginBottomPxFor(sc){ return Math.round(sc.height * appSettings.marginBottomPct / 100) }
    function marginLeftPxFor(sc){ return Math.round(sc.width * appSettings.marginLeftPct / 100) }
    function marginRightPxFor(sc){ return Math.round(sc.width * appSettings.marginRightPct / 100) }
    function cellPadWPxFor(sc){ return Math.round(sc.height * appSettings.cellPadWPct / 100) }
    function cellPadHPxFor(sc){ return Math.round(sc.height * appSettings.cellPadHPct / 100) }
    function padPxFor(sc){ return Math.round(sc.height * 0.007) }
    function cellWFor(sc){ if (!sc) return 100; return iconPxFor(sc) + cellPadWPxFor(sc) + padPxFor(sc)*2 }
    function cellHFor(sc){ return iconPxFor(sc) + fontPxFor(sc)*3 + cellPadHPxFor(sc) }
    function getFreeBounds(sc){ var ml=marginLeftPxFor(sc); var mr=marginRightPxFor(sc); var mt=marginTopPxFor(sc); var mb=marginBottomPxFor(sc); var cw=cellWFor(sc); var ch=cellHFor(sc); return { minX: sc.x+ml, maxX: sc.x+sc.width-mr-cw, minY: sc.y+mt, maxY: sc.y+sc.height-mb-ch, cw: cw, ch: ch } }
    function buildPositionsForScreen(sc){ var b=getFreeBounds(sc); if (b.maxX < b.minX) b.maxX=b.minX; if (b.maxY < b.minY) b.maxY=b.minY; var xs=[]; var ys=[]; for (var x=b.minX; x<=b.maxX+0.01; x+=b.cw){ var xx=Math.min(x,b.maxX); xs.push(xx); if (xx>=b.maxX-0.1) break } for (var y=b.minY; y<=b.maxY+0.01; y+=b.ch){ var yy=Math.min(y,b.maxY); ys.push(yy); if (yy>=b.maxY-0.1) break } if (xs.length===0) xs=[b.minX]; if (ys.length===0) ys=[b.minY]; var out=[]; for (var c=0;c<xs.length;c++){ for (var r=0;r<ys.length;r++){ out.push(Qt.point(xs[c], ys[r])) } } return out }
    function rebuildCache(){ var s=Quickshell.screens; if (!s || s.length===0) return; var arr=[]; for (var i=0;i<s.length;i++) arr.push(s[i]); _sortedScreens=arr.sort(function(a,b){ return a.x-b.x||a.y-b.y }); var out=[]; var set={}; for (var sc of _sortedScreens){ var pts=buildPositionsForScreen(sc); for (var p=0;p<pts.length;p++){ var pp=pts[p]; out.push(pp); set[pp.x+","+pp.y]=true } } _cachedGrid=out; _cachedGridSet=set; var prim=primaryScreen(); if (!prim){ _primaryGrid=out; _primaryGridSet=set; return } var pPts=buildPositionsForScreen(prim); var pOut=[]; var pSet={}; for (var p=0;p<pPts.length;p++){ var pp=pPts[p]; pOut.push(pp); pSet[pp.x+","+pp.y]=true } _primaryGrid=pOut; _primaryGridSet=pSet }
    function gridPos(i){ return i<_cachedGrid.length? _cachedGrid[i] : (_cachedGrid[0]? _cachedGrid[0] : Qt.point(24,24)) }
    function snapToGrid(x,y){ if (_sortedScreens.length===0) return Qt.point(x,y); var sc=screenForPoint(x,y); var b=getFreeBounds(sc); var sx=b.minX+Math.round((x-b.minX)/b.cw)*b.cw; var sy=b.minY+Math.round((y-b.minY)/b.ch)*b.ch; sx=Math.max(b.minX, Math.min(sx, b.maxX)); sy=Math.max(b.minY, Math.min(sy, b.maxY)); return Qt.point(sx,sy) }
    function absoluteToPctEntry(x,y,sc){ if (!sc) sc=screenForPoint(x,y)||primaryScreen()||_sortedScreens[0]; if (!sc) return {screen: "", xPct: 0, yPct: 0}; return {screen: sc.name, xPct: (x-sc.x)/sc.width, yPct: (y-sc.y)/sc.height} }
    function posForFile(name){ var entry=appSettings.positions[name]; if (!entry){ for (var i=0;i<globalModel.count;i++) if (globalModel.get(i,"fileName")===name) return gridPos(i); return gridPos(0) } var sc=null; if (entry.screen) sc=screenByName(entry.screen); var absX; var absY; if (entry.xPct!==undefined){ if (!sc) sc=primaryScreen()||_sortedScreens[0]; if (!sc) return Qt.point(0,0); absX=sc.x + entry.xPct*sc.width; absY=sc.y + entry.yPct*sc.height } else { absX=entry.x; absY=entry.y; if (!sc) sc=screenForPoint(absX,absY)||primaryScreen()||_sortedScreens[0] } if (!sc) return Qt.point(absX,absY); var b=getFreeBounds(sc); absX=Math.max(b.minX, Math.min(absX, b.maxX)); absY=Math.max(b.minY, Math.min(absY, b.maxY)); if (!appSettings.freePlacement) return snapToGrid(absX,absY); return Qt.point(absX,absY) }
    function migratePositions(){ if (!appSettings.positions) return; var cp={}; var changed=false; for (var k in appSettings.positions){ var e=appSettings.positions[k]; if (e && e.xPct===undefined && e.x!==undefined){ var sc=screenForPoint(e.x,e.y)||primaryScreen()||_sortedScreens[0]; if (sc){ cp[k]=absoluteToPctEntry(e.x,e.y,sc); changed=true } else cp[k]=e } else cp[k]=e } if (changed){ appSettings.positions=cp; saveTimer.restart() } }
    function refreshAllPositions(){ for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); if (appSettings.positions && appSettings.positions[fn]){ var p=posForFile(fn); posChanged(fn,p) } } }
    function isFree(p,ex){ if (!appSettings.positions) return true; var sc=screenForPoint(p.x,p.y); var cw=sc?cellWFor(sc):100; var ch=sc?cellHFor(sc):100; for (var k in appSettings.positions){ if (k===ex) continue; var abs=posForFile(k); if (Math.abs(abs.x-p.x)<cw*0.8 && Math.abs(abs.y-p.y)<ch*0.8) return false } return true }
    function nearestFreeGridPosForGroup(x,y,excludeGroup,assigned){ var snap=snapToGrid(x,y); function freeEx(p){ var sc=screenForPoint(p.x,p.y); var cw=sc?cellWFor(sc):100; var ch=sc?cellHFor(sc):100; for (var k in appSettings.positions){ if (excludeGroup.indexOf(k)!==-1) continue; var abs=posForFile(k); if (Math.abs(abs.x-p.x)<cw*0.8 && Math.abs(abs.y-p.y)<ch*0.8) return false } for (var a=0;a<assigned.length;a++){ var ap=assigned[a]; var asc=screenForPoint(ap.x,ap.y); var acw=asc?cellWFor(asc):100; var ach=asc?cellHFor(asc):100; if (Math.abs(ap.x-p.x)<acw*0.8 && Math.abs(ap.y-p.y)<ach*0.8) return false } return true } if (freeEx(snap)) return snap; var sc=screenForPoint(snap.x,snap.y); var b=sc?getFreeBounds(sc):null; if (!b) return snap; for (var r=1;r<25;r++){ for (var dx=-r;dx<=r;dx++){ for (var dy=-r;dy<=r;dy++){ if (Math.abs(dx)!==r && Math.abs(dy)!==r) continue; var cx=snap.x+dx*b.cw; var cy=snap.y+dy*b.ch; if (!_cachedGridSet[cx+","+cy]) continue; var pp=Qt.point(cx,cy); if (freeEx(pp)) return pp } } } return snap }
    function clampPos(x,y){ if (_sortedScreens.length===0) return Qt.point(x,y); var sc=screenForPoint(x,y); var b=getFreeBounds(sc); return Qt.point(Math.max(b.minX, Math.min(x, b.maxX)), Math.max(b.minY, Math.min(y, b.maxY))) }
    function clampPrimaryForGroup(primary){ if (Object.keys(dragGroupOffsets).length===0) return clampPos(primary.x, primary.y); var sc=screenForPoint(primary.x, primary.y); var b=getFreeBounds(sc); var minOffX=1e9; var maxOffX=-1e9; var minOffY=1e9; var maxOffY=-1e9; for (var k in dragGroupOffsets){ var o=dragGroupOffsets[k]; if (o.x<minOffX) minOffX=o.x; if (o.x>maxOffX) maxOffX=o.x; if (o.y<minOffY) minOffY=o.y; if (o.y>maxOffY) maxOffY=o.y } var allowMinX=b.minX - minOffX; var allowMaxX=b.maxX - maxOffX; var allowMinY=b.minY - minOffY; var allowMaxY=b.maxY - maxOffY; var nx=primary.x; var ny=primary.y; if (allowMinX<=allowMaxX) nx=Math.max(allowMinX, Math.min(nx, allowMaxX)); else nx=Math.max(b.minX, Math.min(nx, b.maxX)); if (allowMinY<=allowMaxY) ny=Math.max(allowMinY, Math.min(ny, allowMaxY)); else ny=Math.max(b.minY, Math.min(ny, b.maxY)); return Qt.point(nx,ny) }
    function setPos(n,x,y){ var clamped=clampPos(x,y); var sc=screenForPoint(clamped.x, clamped.y)||primaryScreen()||_sortedScreens[0]; var pct=absoluteToPctEntry(clamped.x, clamped.y, sc); var cp={}; if (appSettings.positions) for (var k in appSettings.positions) cp[k]=appSettings.positions[k]; cp[n]=pct; appSettings.positions=cp; posChanged(n, clamped); bumpZ(n); saveTimer.restart() }
    function tightWForName(name, sc){ if (!sc) sc=primaryScreen()||_sortedScreens[0]; if (!sc) return 100; var cw=cellWFor(sc); var pad=padPxFor(sc); var maxText=cw-pad*2; var est=Math.min(name.length*fontPxFor(sc)*0.6, maxText); return Math.max(iconPxFor(sc), est) + pad*2 }
    function tightHForName(name, sc){ if (!sc) sc=primaryScreen()||_sortedScreens[0]; if (!sc) return 80; var lines=name.length>18?2:1; return iconPxFor(sc)+6+lines*fontPxFor(sc)*1.3+Math.round(sc.height*0.015) }
    function bumpZ(name){ if (!name) return; var arr = appSettings.zOrder; var order=[]; if (arr) for(var i=0;i<arr.length;i++) order.push(arr[i]); var idx=order.indexOf(name); if (idx!==-1) order.splice(idx,1); order.push(name); appSettings.zOrder=order; saveTimer.restart() }
    function startGroupDrag(fileName){ var sel = selectedFiles; var useSel = sel.indexOf(fileName)!==-1; var group=[]; if (useSel) for(var i=0;i<sel.length;i++) group.push(sel[i]); else group.push(fileName); var base=posForFile(fileName); var offs={}; for (var j=0;j<group.length;j++){ var fn=group[j]; var p=posForFile(fn); offs[fn]=Qt.point(p.x-base.x, p.y-base.y) } dragGroupOffsets=offs }
    function updateDragPreview(){ if (draggingFile==="" || appSettings.freePlacement){ dragPreviewPositions={}; return } var sel = selectedFiles; var group=[]; if (sel.length>0) for(var i=0;i<sel.length;i++) group.push(sel[i]); else group.push(draggingFile); var assigned=[]; var map={}; for (var g=0;g<group.length;g++){ var fn=group[g]; var off=dragGroupOffsets[fn]?dragGroupOffsets[fn]:Qt.point(0,0); var desired=Qt.point(currentDragGlobal.x+off.x, currentDragGlobal.y+off.y); var snapped=snapToGrid(desired.x, desired.y); var occupied=false; var sc=screenForPoint(snapped.x, snapped.y); var cw=sc?cellWFor(sc):100; var ch=sc?cellHFor(sc):100; for (var k in appSettings.positions){ if (group.indexOf(k)!==-1) continue; var abs=posForFile(k); if (Math.abs(abs.x-snapped.x)<cw*0.8 && Math.abs(abs.y-snapped.y)<ch*0.8){ occupied=true; break } } for (var a=0;a<assigned.length;a++){ var ap=assigned[a]; var asc=screenForPoint(ap.x,ap.y); var acw=asc?cellWFor(asc):100; var ach=asc?cellHFor(asc):100; if (Math.abs(ap.x-snapped.x)<acw*0.8 && Math.abs(ap.y-snapped.y)<ach*0.8){ occupied=true; break } } var finalPos=occupied?nearestFreeGridPosForGroup(snapped.x, snapped.y, group, assigned):snapped; finalPos=clampPos(finalPos.x, finalPos.y); map[fn]=finalPos; assigned.push(finalPos) } dragPreviewPositions=map }
    function finishGroupDrag(){
        var sel = selectedFiles; var group=[]
        if (sel.length>0) for(var i=0;i<sel.length;i++) group.push(sel[i])
        else if (draggingFile!=="") group.push(draggingFile)
        if (group.length===0){ draggingFile=""; dragGroupOffsets={}; dragPreviewPositions={}; return }
        var assigned=[]; var newPos={}
        for (var g=0;g<group.length;g++){
            var fn=group[g]; var off=dragGroupOffsets[fn]?dragGroupOffsets[fn]:Qt.point(0,0)
            var desired=Qt.point(currentDragGlobal.x+off.x, currentDragGlobal.y+off.y)
            var finalPos=desired
            if (!appSettings.freePlacement){
                finalPos=snapToGrid(desired.x, desired.y)
                var occupied=false; var sc=screenForPoint(finalPos.x, finalPos.y)
                var cw=sc?cellWFor(sc):100; var ch=sc?cellHFor(sc):100
                for (var k in appSettings.positions){ if (group.indexOf(k)!==-1) continue; var abs=posForFile(k); if (Math.abs(abs.x-finalPos.x)<cw*0.8 && Math.abs(abs.y-finalPos.y)<ch*0.8){ occupied=true; break } }
                for (var a=0;a<assigned.length;a++){ var ap=assigned[a]; var asc=screenForPoint(ap.x,ap.y); var acw=asc?cellWFor(asc):100; var ach=asc?cellHFor(asc):100; if (Math.abs(ap.x-finalPos.x)<acw*0.8 && Math.abs(ap.y-finalPos.y)<ach*0.8){ occupied=true; break } }
                if (occupied) finalPos=nearestFreeGridPosForGroup(finalPos.x, finalPos.y, group, assigned)
            }
            finalPos=clampPos(finalPos.x, finalPos.y)
            newPos[fn]=finalPos; assigned.push(finalPos)
        }
        // Batch update - single copy of positions object for instant visual feedback
        var cp={}; if (appSettings.positions) for (var k in appSettings.positions) cp[k]=appSettings.positions[k]
        for (var fn in newPos){
            var sc=screenForPoint(newPos[fn].x, newPos[fn].y)||primaryScreen()||_sortedScreens[0]
            cp[fn]=absoluteToPctEntry(newPos[fn].x, newPos[fn].y, sc)
            posChanged(fn, newPos[fn])
            // bumpZ without extra saveTimer restarts
            var arr = appSettings.zOrder; var order=[]; if (arr) for(var i=0;i<arr.length;i++) order.push(arr[i]); var idx=order.indexOf(fn); if (idx!==-1) order.splice(idx,1); order.push(fn); appSettings.zOrder=order
        }
        appSettings.positions=cp
        saveTimer.restart()
        // Clear drag state AFTER positions set, so no gap where no icon visible
        draggingFile=""; dragGroupOffsets={}; dragPreviewPositions={}
    }
    function compareNamesWithCap(a,b,asc){ var cap=appSettings.sortCapitalization; var res=0; if (cap==="ignore"){ res=a.toLowerCase().localeCompare(b.toLowerCase()) } else if (cap==="capitalized"){ if (a<b) res=-1; else if (a>b) res=1; else res=0 } else if (cap==="lowercase"){ var len=Math.min(a.length,b.length); for (var i=0;i<len;i++){ var ca=a.charCodeAt(i); var cb=b.charCodeAt(i); if (ca===cb) continue; var aIsLower=ca>=97&&ca<=122; var bIsLower=cb>=97&&cb<=122; var aIsUpper=ca>=65&&ca<=90; var bIsUpper=cb>=65&&cb<=90; if (aIsLower&&bIsUpper){ res=-1; break } if (aIsUpper&&bIsLower){ res=1; break } res=ca-cb; break } if (res===0) res=a.length-b.length } return asc?res:-res }
    function sortDesktopByMode(mode){ var prim=primaryScreen(); if (!prim) { rebuildCache(); return } var positions=buildPositionsForScreen(prim); var files=[]; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); var isDir=false; try{ isDir=globalModel.get(i,"fileIsDir") }catch(e){} var fsize=0; try{ fsize=globalModel.get(i,"fileSize") }catch(e){} var fmod=null; try{ fmod=globalModel.get(i,"fileModified") }catch(e){} var suffix=""; try{ suffix=globalModel.get(i,"fileSuffix") }catch(e){ var p=fn.split("."); if (p.length>1) suffix=p[p.length-1].toLowerCase() } files.push({fileName: fn, isDir: isDir, size: fsize, modified: fmod, suffix: suffix}) } var foldersFirst=appSettings.sortFoldersFirst; files.sort(function(a,b){ if (foldersFirst){ if (a.isDir &&!b.isDir) return -1; if (!a.isDir && b.isDir) return 1 } switch(mode){ case "nameAsc": return compareNamesWithCap(a.fileName,b.fileName,true); case "nameDesc": return compareNamesWithCap(a.fileName,b.fileName,false); case "type": { var c=a.suffix.toLowerCase().localeCompare(b.suffix.toLowerCase()); if (c!==0) return c; return compareNamesWithCap(a.fileName,b.fileName,true) } case "size": return (b.size||0)-(a.size||0); case "modified": { var da=a.modified?new Date(a.modified).getTime():0; var db=b.modified?new Date(b.modified).getTime():0; return db-da } default: return 0 } }); var newPos={}; for (var i=0;i<files.length;i++){ var fn=files[i].fileName; var p=i<positions.length?positions[i]:positions[positions.length-1]; newPos[fn]=absoluteToPctEntry(p.x,p.y,prim); posChanged(fn,p) } appSettings.positions=newPos; var order=[]; for (var f=0;f<files.length;f++) order.push(files[f].fileName); appSettings.zOrder=order; saveTimer.restart() }
    function selectAllOnMonitor(name){ var sc=screenByName(name)||primaryScreen(); if (!sc) return; var sel=[]; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); var p=posForFile(fn); if (p.x>=sc.x&&p.x<sc.x+sc.width&&p.y>=sc.y&&p.y<sc.y+sc.height) sel.push(fn) } selectedFiles=sel }
    function selectAllCurrentMonitor(){ var sc=screenForPoint(lastMouseGlobal.x,lastMouseGlobal.y); if (!sc) sc=primaryScreen(); if (!sc) return; selectAllOnMonitor(sc.name) }
    function syncToByFolder(){ var byPos = copyObj(appSettings.positionsByFolder); byPos[desktopPath] = copyObj(appSettings.positions); appSettings.positionsByFolder = byPos; var byZ = copyObj(appSettings.zOrderByFolder); byZ[desktopPath] = copyArr(appSettings.zOrder); appSettings.zOrderByFolder = byZ }
    function moveAllToPrimary(){ var prim=primaryScreen(); if (!prim) return; rebuildCache(); var positions=buildPositionsForScreen(prim); var cp={}; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); var p=i<positions.length?positions[i]:positions[positions.length-1]; cp[fn]=absoluteToPctEntry(p.x,p.y,prim); posChanged(fn,p) } appSettings.positions=cp; appSettings.zOrder=[]; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); bumpZ(fn) } saveTimer.restart() }
    function ensureMissingBatch(){ if (!globalModel||globalModel.count===0) return; if (_cachedGrid.length===0) rebuildCache(); migratePositions(); var miss=[]; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); if(fn&&!(appSettings.positions&&appSettings.positions[fn])) miss.push({name:fn, idx:i}) } if (miss.length>0){ var freeList=[]; for (var p=0;p<_primaryGrid.length;p++){ var pp=_primaryGrid[p]; if (isFree(pp,"")) freeList.push(pp) } if (freeList.length===0) freeList=_primaryGrid; var cp={}; if (appSettings.positions) for (var k in appSettings.positions) cp[k]=appSettings.positions[k]; for (var i=0;i<miss.length;i++){ var p=i<freeList.length?freeList[i]:freeList[freeList.length-1]; var c=clampPos(p.x,p.y); var sc=screenForPoint(c.x,c.y)||primaryScreen(); cp[miss[i].name]=absoluteToPctEntry(c.x,c.y,sc); posChanged(miss[i].name,c) } appSettings.positions=cp } var orderArr = appSettings.zOrder; var order=[]; if (orderArr) for(var i=0;i<orderArr.length;i++) order.push(orderArr[i]); var changed=false; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); if (order.indexOf(fn)===-1){ order.push(fn); changed=true } } if (changed) appSettings.zOrder=order; if (miss.length>0||changed) saveTimer.restart() }
    function updateSelection(){ var gx1=Math.min(selGlobalStart.x, selGlobalEnd.x); var gy1=Math.min(selGlobalStart.y, selGlobalEnd.y); var gx2=Math.max(selGlobalStart.x, selGlobalEnd.x); var gy2=Math.max(selGlobalStart.y, selGlobalEnd.y); var sel=[]; for (var i=0;i<globalModel.count;i++){ var fn=globalModel.get(i,"fileName"); var gp=posForFile(fn); var sc=screenForPoint(gp.x,gp.y); var tw=tightWForName(fn,sc); var th=tightHForName(fn,sc); var cw=sc?cellWFor(sc):100; var cx=gp.x+(cw-tw)/2; var cy=gp.y; if (cx+tw>=gx1&&cx<=gx2&&cy+th>=gy1&&cy<=gy2) sel.push(fn) } selectedFiles=sel }
    function _iconForFile(name, isDir) { if (isDir) return "folder"; var dot = name.lastIndexOf("."); var ext = dot!== -1? name.slice(dot+1).toLowerCase() : ""; switch(ext) { case "png": case "jpg": case "jpeg": case "webp": case "bmp": case "gif": return "image-x-generic"; case "svg": return "image-svg+xml"; case "mp4": case "mkv": case "avi": case "mov": case "webm": return "video-x-generic"; case "mp3": case "flac": case "wav": case "ogg": case "m4a": return "audio-x-generic"; case "pdf": return "application-pdf"; case "zip": case "tar": case "gz": case "7z": case "rar": return "package-x-generic"; case "txt": case "log": return "text-plain"; case "json": return "application-json"; case "html": case "htm": return "text-html"; case "js": case "ts": case "qml": case "py": case "cpp": case "c": case "h": case "rs": case "go": case "sh": return "text-x-script"; case "doc": case "docx": return "x-office-document"; case "xls": case "xlsx": case "csv": return "x-office-spreadsheet"; case "ppt": case "pptx": return "x-office-presentation"; case "desktop": return "application-x-desktop"; default: return "text-x-generic" } }

    Component.onCompleted: {
        settingsFile.reload(); rebuildCache()
        var byPos = appSettings.positionsByFolder; var hasKeys=false; if (byPos) for(var k in byPos){ hasKeys=true; break }
        if (!hasKeys && appSettings.positions){
            var empty=true; for(var k in appSettings.positions){ empty=false; break }
            if (!empty){
                var np={}; np[desktopPath]=copyObj(appSettings.positions); appSettings.positionsByFolder=np
                var nz={}; nz[desktopPath]=copyArr(appSettings.zOrder); appSettings.zOrderByFolder=nz
            }
        }
        _prevDesktopPath = desktopPath; migratePositions(); refreshAllPositions()
        var prim=primaryScreen(); if (prim) lastMouseGlobal=Qt.point(prim.x+prim.width/2, prim.y+prim.height/2)
    }
    Connections { target: Quickshell; function onScreensChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onPrimaryMonitorChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onIconSizePctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onFontSizePctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onMarginTopPctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onMarginBottomPctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onMarginLeftPctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onMarginRightPctChanged(){ rebuildCache(); refreshAllPositions() } }
    Connections { target: appSettings; function onPositionsChanged(){ syncToByFolder() } }
    Connections { target: appSettings; function onZOrderChanged(){ syncToByFolder() } }
    Timer { id: saveTimer; interval: 400; onTriggered: settingsFile.writeAdapter() }
    Timer { id: desktopChangeDebounce; interval: 120; onTriggered: {
        var existing={}; for (var i=0;i<globalModel.count;i++) existing[globalModel.get(i,"fileName")]=true
        var cp={}; var needSave=false; if (appSettings.positions){ for (var k in appSettings.positions){ if (existing[k]) cp[k]=appSettings.positions[k]; else needSave=true } }
        if (needSave){ appSettings.positions=cp }
        var orderArr=appSettings.zOrder; var order=[]; if (orderArr) for(var i=0;i<orderArr.length;i++) order.push(orderArr[i]); var newOrder=[]; for(var i=0;i<order.length;i++){ var n=order[i]; if (existing[n]) newOrder.push(n) } if (newOrder.length!==order.length){ appSettings.zOrder=newOrder; needSave=true }
        if (needSave) saveTimer.restart(); ensureMissingBatch()
    } }

    FileView { id: settingsFile; path: StandardPaths.writableLocation(StandardPaths.ConfigLocation) + "/quickshell/desktop/settings.json"; watchChanges: false; onAdapterUpdated: saveTimer.restart(); JsonAdapter { id: appSettings; property real iconSizePct: 4.8; property real fontSizePct: 1.02; property real marginTopPct: 1.5; property real marginBottomPct: 1.5; property real marginLeftPct: 1.5; property real marginRightPct: 1.5; property real marginPct: 1.5; property real cellPadWPct: 2.8; property real cellPadHPct: 2.2; property bool freePlacement: true; property bool sortFoldersFirst: true; property string sortCapitalization: "ignore"; property string sortMode: "nameAsc"; property string selectionColor: "#3399ff"; property bool textBorderEnabled: true; property string textBorderColor: "#aa000000"; property string textColor: "#ffffff"; property string primaryMonitor: ""; property string desktopFolderPath: ""; property real uiScale: 1.0; property bool showDeleteOption: true; property string terminalCommand: "ptyxis -d %d"; property var positions: ({}); property var zOrder: []; property var positionsByFolder: ({}); property var zOrderByFolder: ({}) } }
    FolderListModel { id: globalModel; folder: desktopUrl; showDirs: true; showDotAndDotDot: false; onCountChanged: desktopChangeDebounce.restart() }
    FolderListModel { id: fileOpsLister; showDirs: true; showDotAndDotDot: false; showFiles: true }

        // ================= NATIVE FILE OPS - QML + POSIX sh only (sync) =================
    QtObject {
        id: fileOps
        function ensureDir(p){
            try {
                var d = Qt.createQmlObject('import QtCore; Directory { path: "'+p.replace(/"/g,'\\"')+'" }', root)
                if(!d.exists) d.mkpath(".")
                d.destroy()
            } catch(e){}
        }
        function getBaseName(p){ var a=p.split("/"); return a[a.length-1] }
        function listDirSync(dirPath){
            var entries=[]
            try {
                var d = Qt.createQmlObject('import QtCore; Directory { path: "'+dirPath.replace(/"/g,'\\"')+'" }', root)
                if(d.entryList){
                    var l = d.entryList()
                    if(l) entries = l
                }
                d.destroy()
            } catch(e){}
            return entries
        }
        function isDir(p){
            try {
                var d = Qt.createQmlObject('import QtCore; Directory { path: "'+p.replace(/"/g,'\\"')+'" }', root)
                var ex = d.exists
                d.destroy()
                return ex
            } catch(e){ return false }
        }
        function copyFileNative(src,dst){
            try {
                var f = Qt.createQmlObject('import QtCore; File { path: "'+src.replace(/"/g,'\\"')+'" }', root)
                var ok = f.copy(dst)
                f.destroy()
                return ok
            } catch(e){ return false }
        }
        function moveFileNative(src,dst){
            try {
                var f = Qt.createQmlObject('import QtCore; File { path: "'+src.replace(/"/g,'\\"')+'" }', root)
                var ok=false
                try { ok = f.rename(dst) } catch(e){}
                if(!ok) try { ok = f.move(dst) } catch(e2){}
                if(!ok){ ok=f.copy(dst); if(ok) f.remove() }
                f.destroy()
                return ok
            } catch(e){ return false }
        }
        function removePathNative(p){
            try {
                var f = Qt.createQmlObject('import QtCore; File { path: "'+p.replace(/"/g,'\\"')+'" }', root)
                try { f.remove() } catch(e){}
                f.destroy()
                var d = Qt.createQmlObject('import QtCore; Directory { path: "'+p.replace(/"/g,'\\"')+'" }', root)
                try { d.removeRecursively() } catch(e){ try { d.remove() } catch(e2){} }
                d.destroy()
            } catch(e){}
        }
        function copyRec(src,dst){
            if(isDir(src)){
                ensureDir(dst)
                var entries = listDirSync(src)
                for(var i=0;i<entries.length;i++){
                    var n=entries[i]
                    if(n==="."||n==="..") continue
                    copyRec(src+"/"+n, dst+"/"+n)
                }
            } else {
                copyFileNative(src,dst)
            }
        }
        function moveRec(src,dst){
            if(!moveFileNative(src,dst)){
                copyRec(src,dst)
                removeRec(src)
            }
        }
        function removeRec(p){
            if(isDir(p)){
                var entries = listDirSync(p)
                for(var i=entries.length-1;i>=0;i--){
                    var n=entries[i]
                    if(n==="."||n==="..") continue
                    removeRec(p+"/"+n)
                }
                try {
                    var d = Qt.createQmlObject('import QtCore; Directory { path: "'+p.replace(/"/g,'\\"')+'" }', root)
                    try { d.remove() } catch(e){ d.removeRecursively() }
                    d.destroy()
                } catch(e){ removePathNative(p) }
            } else {
                removePathNative(p)
            }
        }
        function trashNative(absPath){
            try {
                var dataHome = StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString().replace("file://","")
                if(!dataHome) dataHome = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString().replace("file://","") + "/.local/share"
                var filesDir = dataHome + "/Trash/files"
                var infoDir = dataHome + "/Trash/info"
                ensureDir(filesDir)
                ensureDir(infoDir)
                var base = getBaseName(absPath)
                var destBase = base
                var c=0
                while(true){
                    var test = filesDir + "/" + destBase
                    var exists=false
                    try {
                        var tf = Qt.createQmlObject('import QtCore; File { path: "'+test.replace(/"/g,'\\"')+'" }', root)
                        exists=tf.exists; tf.destroy()
                        var td = Qt.createQmlObject('import QtCore; Directory { path: "'+test.replace(/"/g,'\\"')+'" }', root)
                        if(!exists) exists=td.exists; td.destroy()
                    } catch(e){}
                    if(!exists) break
                    c++; destBase = base + "." + c
                }
                var dest = filesDir + "/" + destBase
                moveRec(absPath, dest)
                var infoPath = infoDir + "/" + destBase + ".trashinfo"
                var d = new Date()
                var iso = d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")+"T"+String(d.getHours()).padStart(2,"0")+":"+String(d.getMinutes()).padStart(2,"0")+":"+String(d.getSeconds()).padStart(2,"0")
                var infoContent = "[Trash Info]\nPath="+absPath+"\nDeletionDate="+iso+"\n"
                try {
                    var infoFile = Qt.createQmlObject('import QtCore; File { path: "'+infoPath.replace(/"/g,'\\"')+'" }', root)
                    if(infoFile.open){ infoFile.open(1); infoFile.write(infoContent); infoFile.close() }
                    infoFile.destroy()
                } catch(e){}
            } catch(e){}
        }
    }

    // DESKTOP ICONS - ALWAYS BOTTOM

    Variants {
        model: Quickshell.screens
        delegate: Component {
            PanelWindow {
                id: win
                required property var modelData
                screen: modelData
                property int screenX: modelData.x
                property int screenY: modelData.y
                property int screenW: modelData.width
                property int screenH: modelData.height
                property int cw: root.cellWFor(modelData)
                property int ch: root.cellHFor(modelData)
                property int iconPx: root.iconPxFor(modelData)
                property int fontPx: root.fontPxFor(modelData)
                anchors { top: true; bottom: true; left: true; right: true }
                exclusionMode: ExclusionMode.Normal
                exclusiveZone: 0
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Bottom
                WlrLayershell.namespace: "quickshell-desktop"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
                Item {
                    id: keyHandler
                    anchors.fill: parent
                    focus: true
                    Keys.onPressed: (event)=>{
                        if ((event.modifiers & Qt.ControlModifier) && event.key===Qt.Key_A){ root.selectAllOnMonitor(modelData.name); event.accepted=true }
                        if (event.key===Qt.Key_Escape){ root.hideAllMenus(); root.clipboardFiles=[]; root.clipboardMode="" }
                    }
                    Shortcut { sequence: "Ctrl+A"; context: Qt.WindowShortcut; onActivated: root.selectAllOnMonitor(modelData.name) }
                }
                DropArea {
                    id: bgDrop
                    anchors.fill: parent
                    z: 0
                    enabled: root.draggingFile===""
                    onEntered: function(drag){ if (drag.hasUrls) drag.accepted=true }
                    onDropped: function(drop){
                        if (!drop.hasUrls) return
                        var baseX = win.screenX + drop.x
                        var baseY = win.screenY + drop.y
                        for (var i=0;i<drop.urls.length;i++){
                            var urlStr = drop.urls[i].toString()
                            var srcPath = decodeURIComponent(urlStr.replace("file://",""))
                            var parts = srcPath.split("/")
                            var fileName = parts[parts.length-1]
                            if (!fileName) continue
                            var dstPath = root.desktopPath + "/" + fileName
                            if (srcPath===dstPath){
                                var tx = baseX + (i%4)*root.cellWFor(win.modelData)
                                var ty = baseY + Math.floor(i/4)*root.cellHFor(win.modelData)
                                root.setPos(fileName, tx, ty)
                                continue
                            }
                            var tx2 = baseX + (i%4)*root.cellWFor(win.modelData)
                            var ty2 = baseY + Math.floor(i/4)*root.cellHFor(win.modelData)
                            root.setPos(fileName, tx2, ty2)
                            // NATIVE MOVE - no execDetached
                            if(srcPath !== dstPath) fileOps.moveRec(srcPath, dstPath)
                        }
                        drop.accept()
                    }
                }
                Rectangle { anchors.fill: parent; z: 1; visible: bgDrop.containsDrag; color: root.toRgba(appSettings.selectionColor,0.15); border.color: appSettings.selectionColor; border.width: 2 }
                MouseArea { anchors.fill: parent; z: 0; acceptedButtons: Qt.LeftButton; enabled: root.draggingFile==="" ; onPressed: (m)=>{ root.lastMouseGlobal=Qt.point(win.screenX+m.x, win.screenY+m.y); keyHandler.forceActiveFocus(); root.hideAllMenus(); if (!(m.modifiers & Qt.ControlModifier)) root.selectedFiles=[]; root.selGlobalStart=Qt.point(win.screenX+m.x, win.screenY+m.y); root.selGlobalEnd=Qt.point(win.screenX+m.x, win.screenY+m.y); root.selActive=true; root.updateSelection() } onPositionChanged: (m)=>{ root.lastMouseGlobal=Qt.point(win.screenX+m.x, win.screenY+m.y); if (!root.selActive) return; root.selGlobalEnd=Qt.point(win.screenX+m.x, win.screenY+m.y); root.updateSelection() } onReleased: { root.selActive=false } }
                Rectangle {
                    id: selRect; z: 2; visible: root.selActive
                    x: { var gx1=Math.min(root.selGlobalStart.x, root.selGlobalEnd.x); var gx2=Math.max(root.selGlobalStart.x, root.selGlobalEnd.x); var ix1=Math.max(gx1, win.screenX); var ix2=Math.min(gx2, win.screenX+win.screenW); return ix1-win.screenX }
                    y: { var gy1=Math.min(root.selGlobalStart.y, root.selGlobalEnd.y); var gy2=Math.max(root.selGlobalStart.y, root.selGlobalEnd.y); var iy1=Math.max(gy1, win.screenY); var iy2=Math.min(gy2, win.screenY+win.screenH); return iy1-win.screenY }
                    width: { var gx1=Math.min(root.selGlobalStart.x, root.selGlobalEnd.x); var gx2=Math.max(root.selGlobalStart.x, root.selGlobalEnd.x); var ix1=Math.max(gx1, win.screenX); var ix2=Math.min(gx2, win.screenX+win.screenW); return Math.max(0, ix2-ix1) }
                    height: { var gy1=Math.min(root.selGlobalStart.y, root.selGlobalEnd.y); var gy2=Math.max(root.selGlobalStart.y, root.selGlobalEnd.y); var iy1=Math.max(gy1, win.screenY); var iy2=Math.min(gy2, win.screenY+win.screenH); return Math.max(0, iy2-iy1) }
                    color: root.toRgba(appSettings.selectionColor,0.18); border.color: appSettings.selectionColor; border.width: 1
                }
                Item {
                    anchors.fill: parent; z: 1; visible: root.draggingFile!=="" &&!appSettings.freePlacement
                    Repeater {
                        model: Object.keys(root.dragPreviewPositions)
                        delegate: Rectangle {
                            required property string modelData
                            property point absPos: root.dragPreviewPositions[modelData]? root.dragPreviewPositions[modelData] : Qt.point(-10000,-10000)
                            property bool inside: absPos.x>=win.screenX-100 && absPos.x<win.screenX+win.screenW+100 && absPos.y>=win.screenY-100 && absPos.y<win.screenY+win.screenH+100
                            visible: inside; x: absPos.x - win.screenX; y: absPos.y - win.screenY; width: win.cw; height: win.ch; radius: 10
                            color: root.toRgba(appSettings.selectionColor,0.20); border.color: appSettings.selectionColor; border.width: 2
                        }
                    }
                }
                Item {
                    anchors.fill: parent; z: 2
                    Repeater {
                        model: globalModel
                        delegate: Item {
                            id: iconRoot
                            required property string fileName
                            required property string filePath
                            required property bool fileIsDir
                            required property int index
                            property point stored: root.posForFile(fileName)
                            property bool isPartOfDrag: root.draggingFile!=="" && root.selectedFiles.indexOf(fileName)!==-1
                            property bool isDragging: root.draggingFile===fileName
                            property bool dropHovered: false
                            property point eff: { if (root.draggingFile!=="" && root.selectedFiles.indexOf(fileName)!==-1){ var off=root.dragGroupOffsets[fileName]; if (!off) off=Qt.point(0,0); return Qt.point(root.currentDragGlobal.x + off.x, root.currentDragGlobal.y + off.y) } return stored }
                            property bool _isDir: { try { return globalModel.isFolder(index) } catch(e) { return fileIsDir } }
                            property bool inside: eff.x>=win.screenX-24&&eff.x<win.screenX+win.screenW&&eff.y>=win.screenY-24&&eff.y<win.screenY+win.screenH
                            property bool isSel: root.selectedFiles.indexOf(fileName)!==-1
                            property bool isCut: root.clipboardMode==="cut" && root.clipboardFiles.indexOf(fileName)!==-1
                            property int pad: root.padPxFor(modelData)
                            property int maxTextW: win.cw - pad*2
                            x: eff.x-win.screenX; y: eff.y-win.screenY; width: win.cw; height: win.ch; visible: inside && !isPartOfDrag
                            z: { if (isPartOfDrag) return 10000; var order=appSettings.zOrder; if (!order) return index; var idx=order.indexOf(fileName); return idx===-1?index:idx }
                            scale: isPartOfDrag?1.06:1.0
                            Component.onCompleted: { stored=root.posForFile(fileName) }
                            Connections { target: root; function onPosChanged(name,pos){ if (name===fileName) stored=pos } }
                            property string _rawIcon: { if (_isDir) return "folder"; if (fileName.endsWith(".desktop")) { try { var e = DesktopEntries.heuristicLookup(filePath); if (e && e.icon) return e.icon } catch(err) {} } return root._iconForFile(fileName, false) }
                            Rectangle {
                                id: tightBg
                                property int tw: Math.max(iconImg.width, nameText.width) + iconRoot.pad*2
                                property int th: iconImg.height + 6 + nameText.height + iconRoot.pad*2
                                width: tw; height: th; x: (win.cw-width)/2; y: 0; radius: 10
                                color: iconRoot.dropHovered? root.toRgba(appSettings.selectionColor,0.40) : isSel?root.toRgba(appSettings.selectionColor,0.22):iconM.containsMouse?"#18ffffff":"transparent"
                                border.width: isSel||iconRoot.dropHovered?1:0; border.color: appSettings.selectionColor
                                IconImage { id: iconImg; anchors.top: parent.top; anchors.topMargin: iconRoot.pad; anchors.horizontalCenter: parent.horizontalCenter; implicitSize: win.iconPx; source: Quickshell.iconPath(iconRoot._rawIcon); opacity: iconRoot.isCut?0.45:1.0 }
                                Text { id: nameText; anchors.top: iconImg.bottom; anchors.topMargin: 6; anchors.horizontalCenter: parent.horizontalCenter; width: Math.min(implicitWidth, iconRoot.maxTextW); text: fileName; color: appSettings.textColor; font.pixelSize: win.fontPx; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter; style: appSettings.textBorderEnabled?Text.Outline:Text.Normal; styleColor: appSettings.textBorderColor; opacity: iconRoot.isCut?0.45:1.0 }
                                MouseArea {
                                    id: iconM; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.LeftButton|Qt.RightButton; enabled: root.draggingFile===""
                                    onPressed: (m)=>{ if (m.button===Qt.LeftButton){ root.hideAllMenus(); keyHandler.forceActiveFocus(); if (!(m.modifiers & Qt.ControlModifier)){ if (root.selectedFiles.indexOf(fileName)===-1) root.selectedFiles=[fileName] } else { var idx=root.selectedFiles.indexOf(fileName); if (idx===-1){ var a=[]; for(var i=0;i<root.selectedFiles.length;i++) a.push(root.selectedFiles[i]); a.push(fileName); root.selectedFiles=a } else { var a=[]; for(var i=0;i<root.selectedFiles.length;i++) if (i!==idx) a.push(root.selectedFiles[i]); root.selectedFiles=a } } var g = tightBg.mapToGlobal(m.x, m.y); root.lastMouseGlobal=Qt.point(g.x, g.y) } }
                                    onClicked: (m)=>{ if (m.button===Qt.RightButton){ keyHandler.forceActiveFocus(); if (root.selectedFiles.indexOf(fileName)===-1) root.selectedFiles=[fileName]; var g = tightBg.mapToGlobal(m.x, m.y); root.lastMouseGlobal=Qt.point(g.x, g.y); root.showIconContextMenuAt(win.modelData.name, root.selectedFiles, Qt.point(g.x, g.y)); m.accepted=true } }
                                    onDoubleClicked: (m)=>{ if (m.button===Qt.LeftButton) Qt.openUrlExternally("file://"+filePath) }
                                }
                                DragHandler { id: dragHandler; target: null; acceptedButtons: Qt.LeftButton; grabPermissions: PointerHandler.CanTakeOverFromItemsView; enabled: root.draggingFile===""||root.draggingFile===fileName; onActiveChanged: { if (active){ if (root.selectedFiles.indexOf(fileName)===-1) root.selectedFiles=[fileName]; root.startGroupDrag(fileName); var lp=centroid.position; root.dragOffset=Qt.point(tightBg.x+lp.x, tightBg.y+lp.y); root.currentDragGlobal=Qt.point(win.screenX+iconRoot.x, win.screenY+iconRoot.y); root.draggingFile=fileName; root.hideAllMenus(); root.dragPreviewPositions={}; if (!appSettings.freePlacement) root.updateDragPreview() } else { if (root.draggingFile===fileName) root.finishGroupDrag() } } onCentroidChanged: { if (active && root.draggingFile===fileName){ var g=tightBg.mapToGlobal(centroid.position.x, centroid.position.y); var ng=Qt.point(g.x-root.dragOffset.x, g.y-root.dragOffset.y); ng=root.clampPos(ng.x, ng.y); ng=root.clampPrimaryForGroup(ng); root.currentDragGlobal=ng; if (!appSettings.freePlacement) root.updateDragPreview() } } }
                                DropArea {
                                    anchors.fill: parent; enabled: fileIsDir && root.draggingFile===""
                                    onEntered: function(drag){ if (drag.hasUrls){ drag.accepted=true; iconRoot.dropHovered=true } }
                                    onExited: { iconRoot.dropHovered=false }
                                    onDropped: function(drop){
                                        iconRoot.dropHovered=false
                                        if (!drop.hasUrls) return
                                        for (var i=0;i<drop.urls.length;i++){
                                            var urlStr=drop.urls[i].toString()
                                            var srcPath=decodeURIComponent(urlStr.replace("file://",""))
                                            var parts=srcPath.split("/")
                                            var fname=parts[parts.length-1]
                                            if (!fname) continue
                                            var dstPath=root.desktopPath + "/" + fileName + "/" + fname
                                            if(srcPath!==dstPath) fileOps.moveRec(srcPath, dstPath)
                                        }
                                        drop.accept()
                                    }
                                }
                            }
                        }
                    }
                }
                MouseArea {
                    anchors.fill: parent; z: 0; acceptedButtons: Qt.RightButton; enabled: root.draggingFile===""
                    onPressed: (m)=>{
                        var gx=win.screenX+m.x; var gy=win.screenY+m.y; var over=false
                        if (appSettings.positions) for (var k in appSettings.positions){
                            var p=root.posForFile(k); var sc=root.screenForPoint(p.x,p.y)
                            var tw=root.tightWForName(k,sc); var th=root.tightHForName(k,sc); var cw=sc?root.cellWFor(sc):100; var cx=p.x+(cw-tw)/2; var cy=p.y
                            if (gx>=cx&&gx<cx+tw&&gy>=cy&&gy<cy+th){ over=true; break }
                        }
                        if (!over){ root.lastMouseGlobal=Qt.point(gx,gy); keyHandler.forceActiveFocus(); root.showBgContextMenuAt(modelData.name, Qt.point(gx,gy)) } else { root.hideAllMenus() }
                        m.accepted=true
                    }
                }
            }
        }
    }

    // DRAG OVERLAY - ONLY DRAGGED ICONS ABOVE ALL WINDOWS
    Variants {
        model: Quickshell.screens
        delegate: Component {
            PanelWindow {
                id: dragWin
                required property var modelData
                screen: modelData
                property int screenX: modelData.x
                property int screenY: modelData.y
                property int screenW: modelData.width
                property int screenH: modelData.height
                property int cw: root.cellWFor(modelData)
                property int ch: root.cellHFor(modelData)
                property int iconPx: root.iconPxFor(modelData)
                property int fontPx: root.fontPxFor(modelData)
                visible: root.draggingFile !== ""
                anchors { top: true; bottom: true; left: true; right: true }
                exclusionMode: ExclusionMode.Ignore
                exclusiveZone: 0
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "quickshell-desktop-drag"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                Item {
                    anchors.fill: parent
                    Repeater {
                        model: root.selectedFiles.length>0 ? root.selectedFiles : (root.draggingFile ? [root.draggingFile] : [])
                        delegate: Item {
                            id: dIcon
                            required property string modelData
                            property string fileName: modelData
                            property bool _isDir: root.isFolder(fileName)
                            property bool isSel: true
                            property bool isCut: root.clipboardMode === "cut" && root.clipboardFiles.indexOf(fileName) !== -1
                            property point absPos: { var off = root.dragGroupOffsets[fileName]; if (!off) off = Qt.point(0, 0); return Qt.point(root.currentDragGlobal.x + off.x, root.currentDragGlobal.y + off.y) }
                            property bool inside: absPos.x >= dragWin.screenX - 120 && absPos.x < dragWin.screenX + dragWin.screenW + 120 && absPos.y >= dragWin.screenY - 120 && absPos.y < dragWin.screenY + dragWin.screenH + 120
                            visible: inside
                            x: absPos.x - dragWin.screenX
                            y: absPos.y - dragWin.screenY
                            width: dragWin.cw
                            height: dragWin.ch
                            scale: 1.06
                            property int pad: root.padPxFor(dragWin.modelData)
                            property int maxTextW: dragWin.cw - pad * 2
                            property string _rawIcon: { if (_isDir) return "folder"; if (fileName.endsWith(".desktop")) { try { var e = DesktopEntries.heuristicLookup(root.desktopPath + "/" + fileName); if (e && e.icon) return e.icon } catch (err) {} } return root._iconForFile(fileName, false) }
                            Rectangle {
                                id: tightBgDrag
                                property int tw: Math.max(iconImgD.width, nameTextD.width) + dIcon.pad * 2
                                property int th: iconImgD.height + 6 + nameTextD.height + dIcon.pad * 2
                                width: tw; height: th; x: (dragWin.cw - width) / 2; y: 0; radius: 10
                                color: dIcon.isSel ? root.toRgba(appSettings.selectionColor, 0.22) : "transparent"
                                border.width: dIcon.isSel ? 1 : 0; border.color: appSettings.selectionColor
                                IconImage { id: iconImgD; anchors.top: parent.top; anchors.topMargin: dIcon.pad; anchors.horizontalCenter: parent.horizontalCenter; implicitSize: dragWin.iconPx; source: Quickshell.iconPath(dIcon._rawIcon); opacity: dIcon.isCut ? 0.45 : 1.0 }
                                Text { id: nameTextD; anchors.top: iconImgD.bottom; anchors.topMargin: 6; anchors.horizontalCenter: parent.horizontalCenter; width: Math.min(implicitWidth, dIcon.maxTextW); text: fileName; color: appSettings.textColor; font.pixelSize: dragWin.fontPx; wrapMode: Text.Wrap; maximumLineCount: 2; elide: Text.ElideRight; horizontalAlignment: Text.AlignHCenter; style: appSettings.textBorderEnabled ? Text.Outline : Text.Normal; styleColor: appSettings.textBorderColor; opacity: dIcon.isCut ? 0.45 : 1.0 }
                            }
                        }
                    }
                }
            }
        }
    }

    // CONTEXT MENUS - OVERLAY LAYER
    Variants {
        model: Quickshell.screens
        delegate: Component {
            PanelWindow {
                id: menuWin
                required property var modelData
                screen: modelData
                visible: (root.bgContextMenuVisible && root.bgContextMenuScreen===modelData.name) || (root.iconContextMenuVisible && root.iconContextMenuScreen===modelData.name)
                anchors { top: true; bottom: true; left: true; right: true }
                exclusionMode: ExclusionMode.Ignore
                exclusiveZone: 0
                color: "transparent"
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "quickshell-desktop-context-menu"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                property bool localSortVisible: false
                Connections { target: root; function onBgContextMenuVisibleChanged(){ if(!root.bgContextMenuVisible) localSortVisible=false } }
                MouseArea {
                    anchors.fill: parent; z: 0; acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPressed: (m)=>{
                        var inside=false
                        if (bgMenu.visible){ var bx=bgMenu.x; var by=bgMenu.y; var bw=bgMenu.width*appSettings.uiScale; var bh=(bgMainCol.implicitHeight+8)*appSettings.uiScale; if (m.x>=bx && m.x<bx+bw && m.y>=by && m.y<by+bh) inside=true }
                        if (!inside && sortMenu.visible){ var sx=sortMenu.x; var sy=sortMenu.y; var sw=sortMenu.width*appSettings.uiScale; var sh=(subCol.implicitHeight+8)*appSettings.uiScale; if (m.x>=sx && m.x<sx+sw && m.y>=sy && m.y<sy+sh) inside=true }
                        if (!inside && iconMenu.visible){ var ix=iconMenu.x; var iy=iconMenu.y; var iw=iconMenu.width*appSettings.uiScale; var ih=(iconMainCol.implicitHeight+8)*appSettings.uiScale; if (m.x>=ix && m.x<ix+iw && m.y>=iy && m.y<iy+ih) inside=true }
                        if (!inside){ root.hideAllMenus(); localSortVisible=false }
                    }
                }
                                Rectangle {
                    id: bgMenu; visible: root.bgContextMenuVisible && root.bgContextMenuScreen===modelData.name; width: 200; height: bgMainCol.implicitHeight+8; radius: 10; color: "#2a2a2a"; border.color: "#444"; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; z: 10
                    x: { var base = root.bgContextMenuGlobalPos.x - modelData.x; var w = width*appSettings.uiScale; var mx = modelData.width - w - 4; if (base>mx) base=mx; if (base<0) base=0; return base }
                    y: { var base = root.bgContextMenuGlobalPos.y - modelData.y; var h = (bgMainCol.implicitHeight+8)*appSettings.uiScale; var my = modelData.height - h - 4; if (base>my) base=my; if (base<0) base=0; return base }
                    Column {
                        id: bgMainCol; anchors.fill: parent; anchors.margins: 4; spacing: 2
                        Rectangle { width: parent.width; height: 32; radius: 7; color:!root.canPaste? "transparent" : pasteMA.containsMouse?"#3a3a3a":"transparent"; opacity: root.canPaste? 1.0 : 0.5; Text { anchors.centerIn: parent; text: root.clipboardMode==="cut" || root.systemClipboardMode==="cut" ? "Move here" : "Paste"; color: root.canPaste? "white" : "#888"; font.pixelSize: 13 } MouseArea { id: pasteMA; anchors.fill: parent; hoverEnabled: true; enabled: root.canPaste; onEntered: menuWin.localSortVisible=false; onClicked: { root.pasteFiles(); root.hideAllMenus(); menuWin.localSortVisible=false } } }
                        Rectangle { width: parent.width; height: 32; radius: 7; color: termBgMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Open Terminal"; color: "white"; font.pixelSize: 13 } MouseArea { id: termBgMA; anchors.fill: parent; hoverEnabled: true; onEntered: menuWin.localSortVisible=false; onClicked: { root.openTerminalAt(root.desktopPath); root.hideAllMenus(); menuWin.localSortVisible=false } } }
                        Rectangle { id: sortItem; width: parent.width; height: 32; radius: 7; color: sortItemMA.containsMouse||menuWin.localSortVisible?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Sort >"; color: "white"; font.pixelSize: 13 } MouseArea { id: sortItemMA; anchors.fill: parent; hoverEnabled: true; onEntered: menuWin.localSortVisible=true; onClicked: menuWin.localSortVisible=!menuWin.localSortVisible } }
                        Rectangle { width: parent.width; height: 1; color: "#333" }
                        Rectangle { width: parent.width; height: 32; radius: 7; color: settingsMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Desktop Settings"; color: "white"; font.pixelSize: 13 } MouseArea { id: settingsMA; anchors.fill: parent; hoverEnabled: true; onEntered: menuWin.localSortVisible=false; onClicked: { root.hideAllMenus(); menuWin.localSortVisible=false; root.settingsVisible=true } } }
                    }
                }
                                Rectangle {
                    id: sortMenu; visible: root.bgContextMenuVisible && root.bgContextMenuScreen===modelData.name && menuWin.localSortVisible; width: 200; height: subCol.implicitHeight+8; radius: 10; color: "#2a2a2a"; border.color: "#444"; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; z: 11
                    x: { var bx=bgMenu.x; var bw=bgMenu.width*appSettings.uiScale; var w=width*appSettings.uiScale; var px=bx+bw+6; if (px+w>modelData.width) px=bx-w-6; return px }
                    y: { var by=bgMenu.y; var h=(subCol.implicitHeight+8)*appSettings.uiScale; var my=modelData.height-h-4; var yy=by; if (yy>my) yy=my; if (yy<0) yy=0; return yy }
                    Column {
                        id: subCol; anchors.fill: parent; anchors.margins: 4; spacing: 2
                        Repeater {
                            model: root.sortDisplayNames
                            delegate: Rectangle {
                                required property int index; required property string modelData; width: parent.width; height: 30; radius: 6; color: subMA.containsMouse?"#3a3a3a":"transparent"
                                Text { anchors.centerIn: parent; text: modelData; color: "white"; font.pixelSize: 12 }
                                MouseArea { id: subMA; anchors.fill: parent; hoverEnabled: true; onClicked: { var mode=root.sortValues[index]; appSettings.sortMode=mode; root.sortDesktopByMode(mode); root.hideAllMenus(); menuWin.localSortVisible=false } }
                            }
                        }
                    }
                }
                                Rectangle {
                    id: iconMenu; visible: root.iconContextMenuVisible && root.iconContextMenuScreen===modelData.name; width: 200; height: iconMainCol.implicitHeight+8; radius: 10; color: "#2a2a2a"; border.color: "#444"; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; z: 12
                    x: { var base = root.iconContextMenuGlobalPos.x - modelData.x; var w=width*appSettings.uiScale; var mx=modelData.width-w-4; if (base>mx) base=mx; if (base<0) base=0; return base }
                    y: { var base = root.iconContextMenuGlobalPos.y - modelData.y; var h=(iconMainCol.implicitHeight+8)*appSettings.uiScale; var my=modelData.height-h-4; if (base>my) base=my; if (base<0) base=0; return base }
                    Column {
                        id: iconMainCol; anchors.fill: parent; anchors.margins: 4; spacing: 2
                        Rectangle { width: parent.width; height: 32; radius: 7; color: copyMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Copy"; color: "white"; font.pixelSize: 13 } MouseArea { id: copyMA; anchors.fill: parent; hoverEnabled: true; onClicked: { root.copyFiles(root.iconContextMenuFiles); root.hideAllMenus() } } }
                        Rectangle { width: parent.width; height: 32; radius: 7; color: cutMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Cut"; color: "white"; font.pixelSize: 13 } MouseArea { id: cutMA; anchors.fill: parent; hoverEnabled: true; onClicked: { root.cutFiles(root.iconContextMenuFiles); root.hideAllMenus() } } }
                        Rectangle { width: parent.width; height: 1; color: "#333" }
                        Rectangle { width: parent.width; height: 32; radius: 7; color: removeMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Remove"; color: "white"; font.pixelSize: 13 } MouseArea { id: removeMA; anchors.fill: parent; hoverEnabled: true; onClicked: { root.trashFiles(root.iconContextMenuFiles); root.hideAllMenus() } } }
                        Rectangle { visible: appSettings.showDeleteOption; width: parent.width; height: visible?32:0; radius: 7; color: deleteMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Delete"; color: "#ff6b6b"; font.pixelSize: 13 } MouseArea { id: deleteMA; anchors.fill: parent; hoverEnabled: true; onClicked: { root.deleteFilesPermanently(root.iconContextMenuFiles); root.hideAllMenus() } } }
                        Rectangle { width: parent.width; height: 1; color: "#333" }
                        Rectangle { visible: root.hasFolderInSelection(root.iconContextMenuFiles); width: parent.width; height: visible?32:0; radius: 7; color: termHereMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Open Terminal Here"; color: "white"; font.pixelSize: 13 } MouseArea { id: termHereMA; anchors.fill: parent; hoverEnabled: true; onClicked: { for(var i=0;i<root.iconContextMenuFiles.length;i++){ var n=root.iconContextMenuFiles[i]; if(root.isFolder(n)){ root.openTerminalAt(root.desktopPath + "/" + n) } } root.hideAllMenus() } } }
                        Rectangle { width: parent.width; height: 32; radius: 7; color: propsMA.containsMouse?"#3a3a3a":"transparent"; Text { anchors.centerIn: parent; text: "Properties"; color: "white"; font.pixelSize: 13 } MouseArea { id: propsMA; anchors.fill: parent; hoverEnabled: true; onClicked: { if (root.iconContextMenuFiles.length>0) root.showProperties(root.iconContextMenuFiles[0]); root.hideAllMenus() } } }
                    }
                }
            }
        }
    }

    Variants {
        model: Quickshell.screens
        delegate: Component {
            PanelWindow {
                required property var modelData; screen: modelData; visible: root.settingsVisible
                anchors { bottom: true } margins { bottom: 36 }
                implicitWidth: labelText.width+40; implicitHeight: labelText.height+20
                exclusionMode: ExclusionMode.Ignore; exclusiveZone: 0; color: "transparent"
                WlrLayershell.layer: WlrLayer.Bottom; WlrLayershell.namespace: "quickshell-desktop-monitor-label"; WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                Rectangle { anchors.fill: parent; radius: 12; color: "#88000000"; Text { id: labelText; anchors.centerIn: parent; text: modelData.name+" "+modelData.width+"x"+modelData.height; color: "#ffffff"; font.pixelSize: 42; font.bold: true; style: Text.Outline; styleColor: "#cc000000" } }
            }
        }
    }

    // PROPERTIES DIALOG
    Window {
        id: propsWindow; visible: root.propertiesVisible; title: "Properties - " + root.propertiesTarget; color: "#1e1e1e"; flags: Qt.Window | Qt.WindowStaysOnTopHint; minimumWidth: 360 * appSettings.uiScale; minimumHeight: 200 * appSettings.uiScale; width: 420 * appSettings.uiScale; height: Math.min(500 * appSettings.uiScale, propsMainCol.implicitHeight * appSettings.uiScale + 50)
        onClosing: (close)=>{ close.accepted=false; root.propertiesVisible=false }
        ScrollView {
            id: propsScroll; anchors.fill: parent; anchors.margins: 12; clip: true; contentWidth: propsMainCol.width * appSettings.uiScale; contentHeight: propsMainCol.implicitHeight * appSettings.uiScale
            ColumnLayout {
                id: propsMainCol; width: (propsScroll.width - 20) / appSettings.uiScale; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; spacing: 10
                Text { text: root.propertiesInfo.fileName||""; color: "white"; font.bold: true; font.pixelSize: 16; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#333" }
                Text { text: "Path: " + (root.propertiesInfo.filePath||""); color: "#ccc"; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Text { text: "Type: " + (root.propertiesInfo.fileIsDir?"Folder":"File") + (root.propertiesInfo.fileSuffix?" (."+root.propertiesInfo.fileSuffix+")":""); color: "#ccc"; font.pixelSize: 12; Layout.fillWidth: true }
                Text { text: "Size: " + (root.propertiesInfo.fileIsDir?"-": (root.propertiesInfo.fileSize? (root.propertiesInfo.fileSize>1024*1024 ? (root.propertiesInfo.fileSize/1024/1024).toFixed(2)+" MB" : (root.propertiesInfo.fileSize/1024).toFixed(1)+" KB") : "0 B")); color: "#ccc"; font.pixelSize: 12 }
                Text { text: "Modified: " + (root.propertiesInfo.fileModified? new Date(root.propertiesInfo.fileModified).toString() : "-"); color: "#ccc"; font.pixelSize: 12; wrapMode: Text.Wrap; Layout.fillWidth: true }
                Item { Layout.fillHeight: true }
                RowLayout { Layout.alignment: Qt.AlignHCenter; Button { text: "Close"; onClicked: root.propertiesVisible=false } }
            }
        }
    }

    // DELETE DIALOG
    Window {
        id: deleteConfirmWindow; visible: root.deleteConfirmVisible; title: "Confirm Delete"; color: "#1e1e1e"; flags: Qt.Window | Qt.Dialog | Qt.WindowStaysOnTopHint; modality: Qt.ApplicationModal; minimumWidth: 320 * appSettings.uiScale; minimumHeight: 120 * appSettings.uiScale; width: 360 * appSettings.uiScale; height: deleteMainCol.implicitHeight * appSettings.uiScale + 50
        onClosing: (close)=>{ close.accepted=false; root.deleteConfirmVisible=false }
        ScrollView {
            id: deleteScroll; anchors.fill: parent; anchors.margins: 12; clip: true; contentWidth: deleteMainCol.width * appSettings.uiScale; contentHeight: deleteMainCol.implicitHeight * appSettings.uiScale
            ColumnLayout {
                id: deleteMainCol; width: (deleteScroll.width - 20) / appSettings.uiScale; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; spacing: 16
                Text { text: "Permanently delete "+root.filesToDelete.length+" item(s)?\nThis cannot be undone."; color: "white"; font.pixelSize: 13; wrapMode: Text.Wrap; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true; Layout.alignment: Qt.AlignHCenter }
                RowLayout { Layout.alignment: Qt.AlignHCenter; spacing: 12; Button { text: "Cancel"; onClicked: root.deleteConfirmVisible=false } Button { text: "Delete"; onClicked: root.doDeletePermanently() } }
            }
        }
    }

    Window {
        id: settingsWindow; visible: root.settingsVisible; width: 580; height: 1020; x: root.settingsWinX; y: root.settingsWinY; title: "Desktop Settings"; color: "#1e1e1e"; flags: Qt.Window | Qt.WindowStaysOnTopHint
        onClosing: (close)=>{ close.accepted=false; root.settingsVisible=false }
        onXChanged: if (visible) root.settingsWinX=x
        onYChanged: if (visible) root.settingsWinY=y
        FolderDialog { id: desktopFolderDialog; title: "Select Desktop Folder"; currentFolder: desktopUrl; onAccepted: { var p=selectedFolder.toString(); if (p.startsWith("file://")) p=p.replace("file://",""); p=decodeURIComponent(p); appSettings.desktopFolderPath=p } }
        ScrollView {
            id: settingsScroll; anchors.fill: parent; anchors.margins: 12; clip: true; contentWidth: mainCol.width * appSettings.uiScale; contentHeight: mainCol.implicitHeight * appSettings.uiScale
            ColumnLayout {
                id: mainCol; width: (settingsScroll.width - 20) / appSettings.uiScale; scale: appSettings.uiScale; transformOrigin: Item.TopLeft; spacing: 14
                Text { text: "Desktop Settings - % of screen"; color: "white"; font.bold: true; font.pixelSize: 16 }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Primary Monitor"; color: "#ccc"; font.pixelSize: 12 } ComboBox { id: primaryCombo; Layout.fillWidth: true; model: { var names=["Auto (first)"]; for (var sc of root._sortedScreens) names.push(sc.name); return names } currentIndex: { if (!appSettings.primaryMonitor||appSettings.primaryMonitor==="") return 0; var idx=root._sortedScreens.findIndex(function(s){ return s.name===appSettings.primaryMonitor }); return idx===-1?0:idx+1 } onActivated: function(idx){ if (idx===0) appSettings.primaryMonitor=""; else appSettings.primaryMonitor=root._sortedScreens[idx-1].name } } Button { text: "Move all icons to primary monitor"; Layout.fillWidth: true; onClicked: root.moveAllToPrimary() } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Terminal Command"; color: "#ccc"; font.pixelSize: 12 } RowLayout { Layout.fillWidth: true; TextField { id: terminalField; Layout.fillWidth: true; text: appSettings.terminalCommand; placeholderText: "ptyxis -d %d"; onAccepted: appSettings.terminalCommand = text; onEditingFinished: appSettings.terminalCommand = text } Button { text: "Reset"; onClicked: { appSettings.terminalCommand = "ptyxis -d %d"; terminalField.text = appSettings.terminalCommand } } } Text { text: "Use %d for current directory. Example: ptyxis -d %d, kitty --directory %d, gnome-terminal --working-directory=%d, foot -D %d. If %d is missing, command runs with dir. Binary must be in PATH."; color: "#888"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Desktop Folder"; color: "#ccc"; font.pixelSize: 12 } RowLayout { Layout.fillWidth: true; TextField { id: desktopFolderField; Layout.fillWidth: true; text: root.desktopPath; placeholderText: root.defaultDesktopPath; onAccepted: appSettings.desktopFolderPath=text } Button { text: "Browse"; onClicked: desktopFolderDialog.open() } Button { text: "Reset"; onClicked: { appSettings.desktopFolderPath=""; desktopFolderField.text=root.defaultDesktopPath } } } Text { text: "Current: "+root.desktopPath; color: "#888"; font.pixelSize: 10; wrapMode: Text.Wrap; Layout.fillWidth: true } }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#333" }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "UI Scale: "+ (appSettings.uiScale*100).toFixed(0)+"%"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0.5; to: 2.0; stepSize: 0.05; value: appSettings.uiScale; onMoved: appSettings.uiScale=value } }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Icon Size: "+appSettings.iconSizePct.toFixed(2)+"%"+" ("+(primaryScreen()?iconPxFor(primaryScreen())+"px":"")+")"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 1; to: 15; stepSize: 0.05; value: appSettings.iconSizePct; onMoved: appSettings.iconSizePct=value } }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Font Size: "+appSettings.fontSizePct.toFixed(2)+"%"+" ("+(primaryScreen()?fontPxFor(primaryScreen())+"px":"")+")"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0.4; to: 6; stepSize: 0.02; value: appSettings.fontSizePct; onMoved: appSettings.fontSizePct=value } }
                Text { text: "Margins % (top/bottom %h, left/right %w)"; color: "#aaa"; font.pixelSize: 11 }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Top: "+appSettings.marginTopPct.toFixed(2)+"%"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0; to: 15; stepSize: 0.05; value: appSettings.marginTopPct; onMoved: appSettings.marginTopPct=value } }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Bottom: "+appSettings.marginBottomPct.toFixed(2)+"%"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0; to: 15; stepSize: 0.05; value: appSettings.marginBottomPct; onMoved: appSettings.marginBottomPct=value } }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Left: "+appSettings.marginLeftPct.toFixed(2)+"%"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0; to: 15; stepSize: 0.05; value: appSettings.marginLeftPct; onMoved: appSettings.marginLeftPct=value } }
                ColumnLayout { Layout.fillWidth: true; spacing: 4; Text { text: "Right: "+appSettings.marginRightPct.toFixed(2)+"%"; color: "#ccc"; font.pixelSize: 12 } Slider { Layout.fillWidth: true; from: 0; to: 15; stepSize: 0.05; value: appSettings.marginRightPct; onMoved: appSettings.marginRightPct=value } }
                RowLayout { Layout.fillWidth: true; Text { Layout.fillWidth: true; text: "Free placement"; color: "#ccc"; font.pixelSize: 11; wrapMode: Text.Wrap } Switch { checked: appSettings.freePlacement; onToggled: appSettings.freePlacement=checked } }
                RowLayout { Layout.fillWidth: true; Text { Layout.fillWidth: true; text: "Show Delete (permanent) in icon menu"; color: "#ccc"; font.pixelSize: 11; wrapMode: Text.Wrap } Switch { checked: appSettings.showDeleteOption; onToggled: appSettings.showDeleteOption=checked } }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#333" }
                Text { text: "Sorting"; color: "white"; font.bold: true; font.pixelSize: 13 }
                RowLayout { Layout.fillWidth: true; Text { Layout.fillWidth: true; text: "Folders first"; color: "#ccc"; font.pixelSize: 12 } Switch { checked: appSettings.sortFoldersFirst; onToggled: appSettings.sortFoldersFirst=checked } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Name first"; color: "#ccc"; font.pixelSize: 12 } ComboBox { id: capCombo; Layout.fillWidth: true; model: root.sortCapitalizationDisplay; currentIndex: root.sortCapitalizationValues.indexOf(appSettings.sortCapitalization)>=0?root.sortCapitalizationValues.indexOf(appSettings.sortCapitalization):0; onActivated: function(idx){ appSettings.sortCapitalization=root.sortCapitalizationValues[idx] } } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Sort by"; color: "#ccc"; font.pixelSize: 12 } ComboBox { id: sortCombo; Layout.fillWidth: true; model: root.sortDisplayNames; currentIndex: root.sortValues.indexOf(appSettings.sortMode)>=0?root.sortValues.indexOf(appSettings.sortMode):0; onActivated: function(idx){ appSettings.sortMode=root.sortValues[idx] } } }
                Button { text: "Sort Now (primary monitor)"; Layout.fillWidth: true; onClicked: root.sortDesktopByMode(appSettings.sortMode) }
                Rectangle { Layout.fillWidth: true; height: 1; color: "#333" }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Selection Color"; color: "#ccc"; font.pixelSize: 12 } RowLayout { Rectangle { width: 28; height: 28; radius: 6; color: appSettings.selectionColor; border.color: "white" } TextField { Layout.fillWidth: true; text: appSettings.selectionColor; onAccepted: appSettings.selectionColor=text } Button { text: "Pick"; onClicked: selColorDlg.open() } } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Font Color"; color: "#ccc"; font.pixelSize: 12 } RowLayout { Rectangle { width: 28; height: 28; radius: 6; color: appSettings.textColor; border.color: "white" } TextField { Layout.fillWidth: true; text: appSettings.textColor; onAccepted: appSettings.textColor=text } Button { text: "Pick"; onClicked: fontColorDlg.open() } } }
                RowLayout { Layout.fillWidth: true; Text { Layout.fillWidth: true; text: "Text Border"; color: "#ccc"; font.pixelSize: 12 } Switch { checked: appSettings.textBorderEnabled; onToggled: appSettings.textBorderEnabled=checked } }
                ColumnLayout { Layout.fillWidth: true; spacing: 6; Text { text: "Border Color"; color: "#ccc"; font.pixelSize: 12 } RowLayout { Rectangle { width: 28; height: 28; radius: 6; color: appSettings.textBorderColor; border.color: "white" } TextField { Layout.fillWidth: true; text: appSettings.textBorderColor; onAccepted: appSettings.textBorderColor=text } Button { text: "Pick"; onClicked: borderColorDlg.open() } } }
                Item { Layout.fillHeight: true; Layout.preferredHeight: 20 }
                RowLayout { Layout.alignment: Qt.AlignRight; spacing: 8; Button { text: "Reset Layout"; onClicked: { appSettings.positions=({}); appSettings.zOrder=[]; root.ensureMissingBatch() } } Button { text: "Close"; onClicked: root.settingsVisible=false } }
            }
        }
        ColorDialog { id: selColorDlg; title: "Selection Color"; selectedColor: appSettings.selectionColor; onAccepted: appSettings.selectionColor=selectedColor.toString() }
        ColorDialog { id: fontColorDlg; title: "Font Color"; selectedColor: appSettings.textColor; onAccepted: appSettings.textColor=selectedColor.toString() }
        ColorDialog { id: borderColorDlg; title: "Border Color"; selectedColor: appSettings.textBorderColor; onAccepted: appSettings.textBorderColor=selectedColor.toString() }
    }

    // ==================== FIXED NATIVE CLIPBOARD + FILE OPS ====================
    property var clipboardFiles: []
    property string clipboardMode: ""
    property bool systemClipboardHasFiles: false
    readonly property bool canPaste: clipboardFiles.length>0 || systemClipboardHasFiles
    property var filesToDelete: []
    property bool deleteConfirmVisible: false
    property string propertiesTarget: ""
    property bool propertiesVisible: false
    property var propertiesInfo: ({})

    function isCutFile(name){ return clipboardMode==="cut" && clipboardFiles.indexOf(name)!==-1 }

    function fileToUri(path){
        var parts = path.split("/")
        var enc = []
        for(var i=0;i<parts.length;i++){
            if(parts[i]==="") enc.push("")
            else enc.push(encodeURIComponent(parts[i]))
        }
        return "file://" + enc.join("/")
    }
    function uriToPath(uri){
        if(!uri) return ""
        var u = uri.trim()
        if(u.startsWith("file://")) u = u.substring(7)
        try { return decodeURIComponent(u) } catch(e){ try { return decodeURI(u) } catch(e2){ return u } }
    }
    function getBaseName(path){ var parts = path.split("/"); return parts[parts.length-1] }
    function getDirName(path){ var idx = path.lastIndexOf("/"); if (idx<=0) return "/"; return path.substring(0, idx) }
    function fileExistsInDesktop(name){
        if(globalModel){
            for(var i=0;i<globalModel.count;i++) if(globalModel.get(i,"fileName")===name) return true
        }
        var full = desktopPath + "/" + name
        try {
            var f = Qt.createQmlObject('import QtCore; File { path: "'+full.replace(/"/g,'\\"')+'" }', root)
            var ex = f.exists
            f.destroy()
            if(ex) return true
            var d = Qt.createQmlObject('import QtCore; Directory { path: "'+full.replace(/"/g,'\\"')+'" }', root)
            var ex2 = d.exists
            d.destroy()
            if(ex2) return true
        } catch(e){}
        return false
    }
    function getUniqueName(baseName){
        if(!fileExistsInDesktop(baseName)) return baseName
        var dotIdx = baseName.lastIndexOf(".")
        var name, ext
        if(dotIdx>0){ name=baseName.substring(0,dotIdx); ext=baseName.substring(dotIdx) } else { name=baseName; ext="" }
        var n=1
        while(true){
            var newName
            if(n===1) newName = name + " (copy)" + ext
            else newName = name + " (copy " + n + ")" + ext
            if(!fileExistsInDesktop(newName)) return newName
            n++
        }
    }

        // ========== MIME CLIPBOARD - QML + POSIX SH ONLY (fixed cut) ==========
    property string systemClipboardMode: "copy"
    property var systemClipboardUris: []
    property int _pasteRetry: 0

    Process {
        id: clipboardOwnerProcess
        stdout: StdioCollector { id: ownerStdout }
        stderr: StdioCollector { id: ownerStderr }
    }
    Process {
        id: shellCopyProcess
        stdout: StdioCollector { id: shellCopyOut }
        stderr: StdioCollector { id: shellCopyErr }
    }
    Process {
        id: shellMoveProcess
        stdout: StdioCollector { id: shellMoveOut }
        stderr: StdioCollector { id: shellMoveErr }
    }
    Process {
        id: sysClipboardReader
        command: ["sh", "-c", "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}; wl-paste -t x-special/gnome-copied-files 2>/dev/null || wl-paste -t text/uri-list 2>/dev/null || xclip -selection clipboard -t x-special/gnome-copied-files -o 2>/dev/null || xclip -selection clipboard -t text/uri-list -o 2>/dev/null || xclip -selection clipboard -o 2>/dev/null || wl-paste 2>/dev/null || echo ''"]
        stdout: StdioCollector {
            id: sysClipboardCollector
            onStreamFinished: {
                var txt = (text || "").trim()
                if(!txt){ root.systemClipboardHasFiles = root.clipboardFiles.length>0; return }
                var lines = txt.split("\n")
                var mode = "copy"
                var uris = []
                if(lines.length>0 && (lines[0]==="cut" || lines[0]==="copy")){
                    mode = lines[0]
                    for(var i=1;i<lines.length;i++){ var l=lines[i].trim(); if(!l || l[0]==="#") continue; uris.push(l) }
                } else {
                    for(var i=0;i<lines.length;i++){ var l=lines[i].trim(); if(!l || l[0]==="#") continue; if(l.indexOf("file://")===0 || l[0]==="/") uris.push(l) }
                }
                if(uris.length>0){
                    root.systemClipboardHasFiles = true
                    root.systemClipboardMode = mode
                    root.systemClipboardUris = uris
                } else {
                    root.systemClipboardHasFiles = root.clipboardFiles.length>0
                }
            }
        }
    }
    function checkSystemClipboard(){
        try { sysClipboardReader.running = false; sysClipboardReader.running = true } catch(e){}
        if(clipboardFiles.length>0) systemClipboardHasFiles = true
    }
    Timer { id: sysClipboardTimer; interval: 900; running: true; repeat: true; onTriggered: { if (!bgContextMenuVisible && !iconContextMenuVisible) root.checkSystemClipboard() } }
    Timer { id: pasteRetryTimer; interval: 300; repeat: false; onTriggered: { root._pasteRetry++; root.pasteFiles() } }
    function shellEscapeSingleQuotes(s){ return s.split("'").join("'\\''") }
    function setSystemClipboard(fullPaths, mode){
        if(!fullPaths || fullPaths.length===0) return
        var uris = []
        for(var i=0;i<fullPaths.length;i++) uris.push(fileToUri(fullPaths[i]))
        var gnomeData = mode + "\n" + uris.join("\n")
        var esc = shellEscapeSingleQuotes(gnomeData)
        try { if(clipboardOwnerProcess.running) clipboardOwnerProcess.running = false } catch(e){}
        try {
            var shCmd = "printf '%s' '" + esc + "' | { wl-copy -t x-special/gnome-copied-files --foreground 2>/dev/null || wl-copy --foreground 2>/dev/null || xclip -selection clipboard -t x-special/gnome-copied-files -i -loops 0 2>/dev/null || xclip -selection clipboard -i -loops 0 2>/dev/null; }"
            clipboardOwnerProcess.command = ["sh", "-c", shCmd]
            clipboardOwnerProcess.running = true
        } catch(e){
            try { Quickshell.clipboardText = gnomeData } catch(e2){}
        }
        systemClipboardHasFiles = true
        systemClipboardMode = mode
        systemClipboardUris = uris
    }
    function shellCopyFallback(src,dst){
        try {
            var escSrc = shellEscapeSingleQuotes(src)
            var escDst = shellEscapeSingleQuotes(dst)
            shellCopyProcess.command = ["sh", "-c", "cp -a -- '" + escSrc + "' '" + escDst + "' 2>/dev/null || cp -r -- '" + escSrc + "' '" + escDst + "'"]
            shellCopyProcess.running = true
        } catch(e){}
    }
    function shellMoveFallback(src,dst){
        try {
            var escSrc = shellEscapeSingleQuotes(src)
            var escDst = shellEscapeSingleQuotes(dst)
            shellMoveProcess.command = ["sh", "-c", "mv -- '" + escSrc + "' '" + escDst + "' 2>/dev/null || mv -f -- '" + escSrc + "' '" + escDst + "'"]
            shellMoveProcess.running = true
        } catch(e){}
    }
    function copyFiles(files){ if(!files||files.length===0) return; clipboardFiles = files.slice(); clipboardMode="copy"; var full=files.map(function(n){ return root.desktopPath+"/"+n }); setSystemClipboard(full,"copy") }
    function cutFiles(files){ if(!files||files.length===0) return; clipboardFiles = files.slice(); clipboardMode="cut"; var full=files.map(function(n){ return root.desktopPath+"/"+n }); setSystemClipboard(full,"cut") }
    function clearClipboard(){ clipboardFiles=[]; clipboardMode=""; systemClipboardHasFiles=false; systemClipboardUris=[]; try{ if(clipboardOwnerProcess.running) clipboardOwnerProcess.running=false }catch(e){} try{ Quickshell.clipboardText="" }catch(e){} }

    // Pure QML native file ops - no cp/mv/rm/gio binaries
    // Pure QML native file ops - wrappers
    function nativeCopyRec(src,dst){ fileOps.copyRec(src,dst); return true }
    function nativeMoveRec(src,dst){ fileOps.moveRec(src,dst); return true }
    function nativeRemoveRec(p){ fileOps.removeRec(p) }
    function nativeTrash(path){
        try {
            var dataHome = StandardPaths.writableLocation(StandardPaths.GenericDataLocation).toString().replace("file://","")
            if(!dataHome || dataHome==="") dataHome = StandardPaths.writableLocation(StandardPaths.HomeLocation).toString().replace("file://","") + "/.local/share"
            var filesDir = dataHome + "/Trash/files"
            var infoDir = dataHome + "/Trash/info"
            try {
                var mk1 = Qt.createQmlObject('import QtCore; Directory { path: "'+filesDir.replace(/"/g,'\\"')+'" }', root)
                if(!mk1.exists) mk1.mkpath(".")
                mk1.destroy()
                var mk2 = Qt.createQmlObject('import QtCore; Directory { path: "'+infoDir.replace(/"/g,'\\"')+'" }', root)
                if(!mk2.exists) mk2.mkpath(".")
                mk2.destroy()
            } catch(e){}
            var base = getBaseName(path)
            var destBase = base
            var counter=0
            while(true){
                var test = filesDir + "/" + destBase
                var exists=false
                try {
                    var tf = Qt.createQmlObject('import QtCore; File { path: "'+test.replace(/"/g,'\\"')+'" }', root)
                    exists = tf.exists; tf.destroy()
                    var td = Qt.createQmlObject('import QtCore; Directory { path: "'+test.replace(/"/g,'\\"')+'" }', root)
                    if(!exists) exists = td.exists; td.destroy()
                } catch(e){}
                if(!exists) break
                counter++; destBase = base + "." + counter
            }
            var dest = filesDir + "/" + destBase
            nativeMoveRec(path, dest)
            var infoPath = infoDir + "/" + destBase + ".trashinfo"
            var d = new Date()
            var iso = d.getFullYear()+"-"+String(d.getMonth()+1).padStart(2,"0")+"-"+String(d.getDate()).padStart(2,"0")+"T"+String(d.getHours()).padStart(2,"0")+":"+String(d.getMinutes()).padStart(2,"0")+":"+String(d.getSeconds()).padStart(2,"0")
            var infoContent = "[Trash Info]\nPath="+path+"\nDeletionDate="+iso+"\n"
            try {
                var infoFile = Qt.createQmlObject('import QtCore; File { path: "'+infoPath.replace(/"/g,'\\"')+'" }', root)
                if(infoFile.open) {
                    infoFile.open(1)
                    infoFile.write(infoContent)
                    infoFile.close()
                }
                infoFile.destroy()
            } catch(e){}
        } catch(e){}
    }

    function trashFiles(files){
        for(var i=0;i<files.length;i++){
            var p = desktopPath + "/" + files[i]
            nativeTrash(p)
        }
    }
    function deleteFilesPermanently(files){ filesToDelete = files.slice(); deleteConfirmVisible = true }
    function doDeletePermanently(){
        for(var i=0;i<filesToDelete.length;i++){
            var p = desktopPath + "/" + filesToDelete[i]
            nativeRemoveRec(p)
        }
        filesToDelete=[]; deleteConfirmVisible=false
    }

    function parseTerminalCommand(cmd, dirPath){
        var replaced = cmd.split("%d").join(dirPath)
        var args = []
        var current = ""
        var inSingle = false
        var inDouble = false
        for (var i=0;i<replaced.length;i++){
            var c = replaced[i]
            if (c === "'" && !inDouble){ inSingle = !inSingle; continue }
            if (c === '"' && !inSingle){ inDouble = !inDouble; continue }
            if (c === " " && !inSingle && !inDouble){ if (current.length>0){ args.push(current); current="" } } else { current += c }
        }
        if (current.length>0) args.push(current)
        return args
    }
    function openTerminalAt(dirPath){
        var tmpl = appSettings.terminalCommand
        if(!tmpl || tmpl.trim()==="") tmpl = "ptyxis -d %d"
        var args = parseTerminalCommand(tmpl, dirPath)
        if (args.length>0) Quickshell.execDetached(args)
    }
    function isFolder(name){
        for (var i=0;i<globalModel.count;i++) if (globalModel.get(i,"fileName")===name) return globalModel.get(i,"fileIsDir")
        return false
    }
    function hasFolderInSelection(files){ if(!files) return false; for (var i=0;i<files.length;i++) if (isFolder(files[i])) return true; return false }

    function pasteFiles(){
        var srcList=[]
        var mode="copy"
        if(clipboardFiles.length>0){
            for(var i=0;i<clipboardFiles.length;i++) srcList.push(desktopPath+"/"+clipboardFiles[i])
            mode=clipboardMode
        } else if(systemClipboardUris.length>0){
            mode=systemClipboardMode
            for(var j=0;j<systemClipboardUris.length;j++){
                var pp = uriToPath(systemClipboardUris[j])
                if(pp) srcList.push(pp)
            }
        } else {
            var clip = ""
            try { clip = Quickshell.clipboardText } catch(e){}
            if(!clip) {
                if(root._pasteRetry < 3){
                    checkSystemClipboard()
                    pasteRetryTimer.restart()
                } else {
                    root._pasteRetry = 0
                }
                return
            }
            root._pasteRetry = 0
            var lines = clip.split("\n")
            var uriLines=[]
            if(lines.length>0 && (lines[0]==="cut"||lines[0]==="copy")){
                mode=lines[0]
                for(var k=1;k<lines.length;k++){ var l=lines[k].trim(); if(!l||l[0]==="#") continue; uriLines.push(l) }
            } else {
                for(var k=0;k<lines.length;k++){ var l2=lines[k].trim(); if(!l2||l2[0]==="#") continue; if(l2.indexOf("file://")===0 || l2[0]==="/") uriLines.push(l2) }
            }
            for(var j=0;j<uriLines.length;j++){
                var pp = uriToPath(uriLines[j])
                if(pp) srcList.push(pp)
            }
        }
        if(srcList.length===0){
            if(root._pasteRetry < 3){
                checkSystemClipboard()
                pasteRetryTimer.restart()
            } else {
                root._pasteRetry = 0
            }
            return
        }
        root._pasteRetry = 0
        var externalCut = (clipboardFiles.length===0 && systemClipboardUris.length>0 && mode==="cut")
        var movedAny = false
        for(var s=0;s<srcList.length;s++){
            var src = srcList[s]
            if(!src) continue
            var base = getBaseName(src)
            var destDir = desktopPath
            var dest = destDir+"/"+base
            var srcDir = getDirName(src)
            if(srcDir===destDir && fileExistsInDesktop(base) && mode==="copy"){
                dest = destDir+"/"+getUniqueName(base)
            } else if(fileExistsInDesktop(base)){
                if(mode==="copy"){
                    dest = destDir+"/"+getUniqueName(base)
                } else {
                    if(src!==dest) dest = destDir+"/"+getUniqueName(base)
                    else continue
                }
            }
            if(src===dest) continue
            // Try move/copy, check if dest exists after
            var destExistsBefore = false
            try {
                var chk = Qt.createQmlObject('import QtCore; File { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                destExistsBefore = chk.exists
                chk.destroy()
                if(!destExistsBefore){
                    var chkD = Qt.createQmlObject('import QtCore; Directory { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                    destExistsBefore = chkD.exists
                    chkD.destroy()
                }
            } catch(e){}
            if(mode==="cut"){
                fileOps.moveRec(src, dest)
                try {
                    var chk2 = Qt.createQmlObject('import QtCore; File { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                    var existsAfter = chk2.exists
                    chk2.destroy()
                    if(!existsAfter){
                        var chkD2 = Qt.createQmlObject('import QtCore; Directory { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                        existsAfter = chkD2.exists
                        chkD2.destroy()
                    }
                    if(!existsAfter){
                        fileOps.copyRec(src, dest)
                        var chk3 = Qt.createQmlObject('import QtCore; File { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                        var existsAfter2 = chk3.exists
                        chk3.destroy()
                        if(!existsAfter2){
                            var chkD3 = Qt.createQmlObject('import QtCore; Directory { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                            existsAfter2 = chkD3.exists
                            chkD3.destroy()
                        }
                        if(existsAfter2){
                            fileOps.removeRec(src)
                        } else {
                            shellMoveFallback(src, dest)
                        }
                    }
                } catch(e){
                    shellMoveFallback(src, dest)
                }
            } else {
                fileOps.copyRec(src, dest)
                try {
                    var chk2c = Qt.createQmlObject('import QtCore; File { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                    var existsAfterC = chk2c.exists
                    chk2c.destroy()
                    if(!existsAfterC){
                        var chkD2c = Qt.createQmlObject('import QtCore; Directory { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                        existsAfterC = chkD2c.exists
                        chkD2c.destroy()
                    }
                    if(!existsAfterC){
                        shellCopyFallback(src, dest)
                    }
                } catch(e){
                    shellCopyFallback(src, dest)
                }
            }
            try {
                var chkFinal = Qt.createQmlObject('import QtCore; File { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                if(chkFinal.exists) movedAny = true
                chkFinal.destroy()
                if(!movedAny){
                    var chkFinalD = Qt.createQmlObject('import QtCore; Directory { path: "'+dest.replace(/"/g,'\\"')+'" }', root)
                    if(chkFinalD.exists) movedAny = true
                    chkFinalD.destroy()
                }
            } catch(e){}
        }
        if(externalCut){
            if(movedAny){
                systemClipboardUris=[]
                systemClipboardHasFiles=false
                systemClipboardMode="copy"
                try {
                    clipboardOwnerProcess.command = ["sh", "-c", "printf '' | wl-copy --foreground 2>/dev/null & sleep 0.15; printf '' | wl-copy -t x-special/gnome-copied-files --foreground 2>/dev/null & sleep 0.15; printf '' | xclip -selection clipboard -i 2>/dev/null; true"]
                    clipboardOwnerProcess.running = true
                } catch(e){}
            } else {
                if(root._pasteRetry < 2){
                    checkSystemClipboard()
                    pasteRetryTimer.restart()
                }
            }
        }
        if(mode==="cut" && clipboardFiles.length>0) clearClipboard()
        try {
            var cur = globalModel.folder
            globalModel.folder = ""
            globalModel.folder = cur
        } catch(e){
            try { desktopChangeDebounce.restart() } catch(e2){}
        }
    }

    function showProperties(fileName){


        propertiesTarget=fileName
        for (var i=0;i<globalModel.count;i++) if (globalModel.get(i,"fileName")===fileName){
            propertiesInfo={ fileName: globalModel.get(i,"fileName"), filePath: globalModel.get(i,"filePath"), fileSize: globalModel.get(i,"fileSize"), fileModified: globalModel.get(i,"fileModified"), fileIsDir: globalModel.get(i,"fileIsDir"), fileSuffix: globalModel.get(i,"fileSuffix") }
            break
        }
        propertiesVisible=true
    }
}
