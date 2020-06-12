//
//  FolioReaderPage.swift
//  FolioReaderKit
//
//  Created by Heberti Almeida on 10/04/15.
//  Copyright (c) 2015 Folio Reader. All rights reserved.
//

import UIKit
import SafariServices
import MenuItemKit
import SwiftSoup

extension String {
  func replaceCharactersFromSet(characterSet: CharacterSet, replacementString: String = "") -> String {
    components(separatedBy: characterSet).joined(separator: replacementString)
  }
}

/// Protocol which is used from `FolioReaderPage`s.
@objc public protocol FolioReaderPageDelegate: class {
  
  /**
   Notify that the page will be loaded. Note: The webview content itself is already loaded at this moment. But some java script operations like the adding of class based on click listeners will happen right after this method. If you want to perform custom java script before this happens this method is the right choice. If you want to modify the html content (and not run java script) you have to use `htmlContentForPage()` from the `FolioReaderCenterDelegate`.
   
   - parameter page: The loaded page
   */
  @objc optional func pageWillLoad(_ page: FolioReaderPage)
  
  /**
   Notifies that page did load. A page load doesn't mean that this page is displayed right away, use `pageDidAppear` to get informed about the appearance of a page.
   
   - parameter page: The loaded page
   */
  @objc optional func pageDidLoad(_ page: FolioReaderPage)
  
  /**
   Notifies that page receive tap gesture.
   
   - parameter recognizer: The tap recognizer
   */
  @objc optional func pageDidTap(at point: CGPoint, withSelectedWord selectedWord: String?)
  @objc optional func pageDidTap(at point: CGPoint, withSelectedSentence selectedSentece: String?)
}

open class FolioReaderPage: UICollectionViewCell, UIWebViewDelegate, UIGestureRecognizerDelegate {
  weak var delegate: FolioReaderPageDelegate?
  weak var readerContainer: FolioReaderContainer?
  
  /// The index of the current page. Note: The index start at 1!
  open var pageNumber: Int!
  open var webView: FolioReaderWebView?
  
  private var shouldHandleTap = true
  fileprivate var colorView: UIView!
  fileprivate var shouldShowBar = true
  fileprivate var menuIsVisible = false
  private var currentHighlightID: String?
  private var oneTapGesture: UITapGestureRecognizer?
  private var twoTapsGesture: UITapGestureRecognizer?
  private var sentences: [String] = []
  private var currentSentenceIndex: Int = 0
  
  fileprivate var readerConfig: FolioReaderConfig {
    guard let readerContainer = readerContainer else { return FolioReaderConfig() }
    return readerContainer.readerConfig
  }
  
  fileprivate var book: FRBook {
    guard let readerContainer = readerContainer else { return FRBook() }
    return readerContainer.book
  }
  
  fileprivate var folioReader: FolioReader {
    guard let readerContainer = readerContainer else { return FolioReader() }
    return readerContainer.folioReader
  }
  
  // MARK: - View life cicle
  
  public override init(frame: CGRect) {
    // Init explicit attributes with a default value. The `setup` function MUST be called to configure the current object with valid attributes.
    self.readerContainer = FolioReaderContainer(withConfig: FolioReaderConfig(), folioReader: FolioReader(), epubPath: "")
    super.init(frame: frame)
    self.backgroundColor = UIColor.clear
    
    NotificationCenter.default.addObserver(self, selector: #selector(refreshPageMode), name: NSNotification.Name(rawValue: "needRefreshPageMode"), object: nil)
  }
  
  public func setup(withReaderContainer readerContainer: FolioReaderContainer) {
    self.readerContainer = readerContainer
    guard let readerContainer = self.readerContainer else { return }
    
    if webView == nil {
      webView = FolioReaderWebView(frame: webViewFrame(), readerContainer: readerContainer)
      webView?.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      webView?.dataDetectorTypes = .link
      webView?.scrollView.showsVerticalScrollIndicator = false
      webView?.scrollView.showsHorizontalScrollIndicator = false
      webView?.backgroundColor = .clear
      self.contentView.addSubview(webView!)
    }
    webView?.delegate = self
    
    if colorView == nil {
      colorView = UIView()
      colorView.backgroundColor = self.readerConfig.nightModeBackground
      webView?.scrollView.addSubview(colorView)
    }
    
    // Remove all gestures before adding new one
    webView?.gestureRecognizers?.forEach({ gesture in
      webView?.removeGestureRecognizer(gesture)
    })
    let oneTap = UITapGestureRecognizer(target: self, action: #selector(handleTapGesture(_:)))
    oneTap.numberOfTapsRequired = 1
    oneTap.delegate = self
    self.oneTapGesture = oneTap
    contentView.addGestureRecognizer(oneTap)
    
    let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoTaps(_:)))
    twoTap.numberOfTapsRequired = 2
    twoTap.delegate = self
    self.twoTapsGesture = twoTap
    contentView.addGestureRecognizer(twoTap)
  }
  
  required public init?(coder aDecoder: NSCoder) {
    fatalError("storyboards are incompatible with truth and beauty")
  }
  
  deinit {
    webView?.scrollView.delegate = nil
    webView?.delegate = nil
    NotificationCenter.default.removeObserver(self)
  }
  
  override open func layoutSubviews() {
    super.layoutSubviews()
    
    webView?.setupScrollDirection()
    webView?.frame = webViewFrame()
  }
  
  func webViewFrame() -> CGRect {
    guard (self.readerConfig.hideBars == false) else {
      return bounds
    }
    
    let statusbarHeight = UIApplication.shared.statusBarFrame.size.height
    let navBarHeight = self.folioReader.readerCenter?.navigationController?.navigationBar.frame.size.height ?? CGFloat(0)
    let navTotal = self.readerConfig.shouldHideNavigationOnTap ? 0 : statusbarHeight + navBarHeight
    let paddingTop: CGFloat = 20
    let paddingBottom: CGFloat = 30
    
    return CGRect(
      x: bounds.origin.x,
      y: self.readerConfig.isDirection(bounds.origin.y + navTotal, bounds.origin.y + navTotal + paddingTop, bounds.origin.y + navTotal),
      width: bounds.width,
      height: self.readerConfig.isDirection(bounds.height - navTotal, bounds.height - navTotal - paddingTop - paddingBottom, bounds.height - navTotal)
    )
  }
  
  func loadHTMLString(_ htmlContent: String!, baseURL: URL!) {
    // Insert the stored highlights to the HTML
    let tempHtmlContent = htmlContentWithInsertHighlights(htmlContent)
    let finalHtmlContent = htmlWithInsertSentenceDots(tempHtmlContent)
    // Load the html into the webview
    webView?.alpha = 0
    webView?.loadHTMLString(finalHtmlContent, baseURL: baseURL)
  }
  
  // MARK: - Highlights
  
  fileprivate func htmlContentWithInsertHighlights(_ htmlContent: String) -> String {
    var tempHtmlContent = htmlContent as NSString
    // Restore highlights
    guard let bookId = (self.book.name as NSString?)?.deletingPathExtension else {
      return tempHtmlContent as String
    }
    
    let highlights = Highlight.allByBookId(withConfiguration: self.readerConfig, bookId: bookId, andPage: pageNumber as NSNumber?)
    
    if (highlights.count > 0) {
      for item in highlights {
        let style = HighlightStyle.classForStyle(item.type)
        
        var tag = ""
        if let _ = item.noteForHighlight {
          tag = "<highlight id=\"\(item.highlightId!)\" onclick=\"callHighlightWithNoteURL(this);\" class=\"\(style)\">\(item.content!)</highlight>"
        } else {
          tag = "<highlight id=\"\(item.highlightId!)\" onclick=\"callHighlightURL(this);\" class=\"\(style)\">\(item.content!)</highlight>"
        }
        
        var locator = item.contentPre + item.content
        locator += item.contentPost
        locator = Highlight.removeSentenceSpam(locator) /// Fix for Highlights
        
        let range: NSRange = tempHtmlContent.range(of: locator, options: .literal)
        
        if range.location != NSNotFound {
          let newRange = NSRange(location: range.location + item.contentPre.count, length: item.content.count)
          tempHtmlContent = tempHtmlContent.replacingCharacters(in: newRange, with: tag) as NSString
        } else {
          print("highlight range not found")
        }
      }
    }
    return tempHtmlContent as String
  }
  
  private func sentenceTag(id: Int) -> String {
    return """
    . <svg class="three-dot" id="sentence-\(id)" onclick="highlightSentence(this)"  width="20" height="18" viewBox="0 0 3 13" xmlns="http://www.w3.org/2000/svg">
        <circle class="origin-dot" cx="1.5" cy="1.5" r="1.5" fill="#63A1FF"/>
        <circle cx="1.5" cy="6.5" r="1.5" fill="#63A1FF"/>
        <circle cx="1.5" cy="11.5" r="1.5" fill="#63A1FF"/>
    </svg>
    """
  }
  
  private func htmlWithInsertSentenceDots(_ htmlContent: String) -> String {
    do {
      sentences = []
      currentSentenceIndex = 0
      let doc = try parse(htmlContent)
      let parahraphs = try doc.select("p")
      let colophons = try doc.getElementsByClass("colophon")
      try colophons.remove()
      let h1 = try doc.select("h1")
      let h2 = try doc.select("h2")
      let h3 = try doc.select("h3")
      let links = try doc.select("a[href]")
      for link in links {
        if (try? link.className()) != "xhtmltoc" {
          try? link.remove()
        }
      }
      try? insertTag(for: h1)
      try? insertTag(for: h2)
      try? insertTag(for: h3)
      try? insertTag(for: parahraphs)
      try? insertTag(for: links)
      return try doc.outerHtml()
    } catch Exception.Error(let type, let message) {
      print(message)
      return htmlContent
    } catch {
      print(error)
      return htmlContent
    }
  }
  
  private func insertTag(for elements: Elements) throws {
    try elements.forEach { paragraph in
      let paragraphText = try paragraph.text()
      if paragraphText.rangeOfCharacter(from: .lowercaseLetters) != nil {
        let sentences = paragraphText.components(separatedBy: ".")
        self.sentences.append(contentsOf: sentences)
        let newHtml = sentences.map { sentence -> String in
          defer {
            currentSentenceIndex += 1
          }
          return sentence.count > 1 ? sentence.appending(sentenceTag(id: currentSentenceIndex)) : sentence
        }.joined()
        try paragraph.html(newHtml)
      }
    }
  }
  
  // MARK: - WKWebView Delegate
  
  open func webViewDidFinishLoad(_ webView: UIWebView) {
    guard let webView = webView as? FolioReaderWebView else {
      return
    }
    
    delegate?.pageWillLoad?(self)
    
    // Add the custom class based onClick listener
    self.setupClassBasedOnClickListeners()
    
    refreshPageMode()
    
    if self.readerConfig.enableTTS && !self.book.hasAudio {
      webView.js("wrappingSentencesWithinPTags()")
      
      if let audioPlayer = self.folioReader.readerAudioPlayer, (audioPlayer.isPlaying() == true) {
        audioPlayer.readCurrentSentence()
      }
    }
    
    let direction: ScrollDirection = self.folioReader.needsRTLChange ? .positive(withConfiguration: self.readerConfig) : .negative(withConfiguration: self.readerConfig)
    
    if (self.folioReader.readerCenter?.pageScrollDirection == direction &&
      self.folioReader.readerCenter?.isScrolling == true &&
      self.readerConfig.scrollDirection != .horizontalWithVerticalContent) {
      scrollPageToBottom()
    }
    
    UIView.animate(withDuration: 0.2, animations: {webView.alpha = 1}, completion: { finished in
      webView.isColors = false
      self.webView?.createMenu(options: false)
    })
    
    delegate?.pageDidLoad?(self)
  }
  
  open func removeLastHighlight() {
    webView?.js("removeThisHighlight()")
    webView?.js("removeSentenceHighlight()")
  }
  
  open func webView(_ webView: UIWebView, shouldStartLoadWith request: URLRequest, navigationType: UIWebView.NavigationType) -> Bool {
    guard
      let webView = webView as? FolioReaderWebView,
      let scheme = request.url?.scheme else {
        return true
    }
    
    guard let url = request.url else { return false }
    
    if scheme == "highlight" || scheme == "highlight-with-note" {
      shouldShowBar = false
      webView.remove()
      return false
    } else if scheme == "play-audio" {
      guard let decoded = url.absoluteString.removingPercentEncoding else { return false }
      let index = decoded.index(decoded.startIndex, offsetBy: 13)
      let playID = String(decoded[index...])
      let chapter = self.folioReader.readerCenter?.getCurrentChapter()
      let href = chapter?.href ?? ""
      self.folioReader.readerAudioPlayer?.playAudio(href, fragmentID: playID)
      
      return false
    } else if scheme == "file" {
      
      let anchorFromURL = url.fragment
      
      // Handle internal url
      if !url.pathExtension.isEmpty {
        let pathComponent = (self.book.opfResource.href as NSString?)?.deletingLastPathComponent
        guard let base = ((pathComponent == nil || pathComponent?.isEmpty == true) ? self.book.name : pathComponent) else {
          return true
        }
        
        let path = url.path
        let splitedPath = path.components(separatedBy: base)
        
        // Return to avoid crash
        if (splitedPath.count <= 1 || splitedPath[1].isEmpty) {
          return true
        }
        
        let href = splitedPath[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hrefPage = (self.folioReader.readerCenter?.findPageByHref(href) ?? 0) + 1
        
        if (hrefPage == pageNumber) {
          // Handle internal #anchor
          if anchorFromURL != nil {
            handleAnchor(anchorFromURL!, avoidBeginningAnchors: false, animated: true)
            return false
          }
        } else {
          self.folioReader.readerCenter?.changePageWith(href: href, animated: true)
        }
        return false
      }
      
      // Handle internal #anchor
      if anchorFromURL != nil {
        handleAnchor(anchorFromURL!, avoidBeginningAnchors: false, animated: true)
        return false
      }
      
      return true
    } else if scheme == "mailto" {
      print("Email")
      return true
    } else if url.absoluteString != "about:blank" && scheme.contains("http") && navigationType == .linkClicked {
      let safariVC = SFSafariViewController(url: request.url!)
      safariVC.view.tintColor = self.readerConfig.tintColor
      self.folioReader.readerCenter?.present(safariVC, animated: true, completion: nil)
      return false
    } else {
      // Check if the url is a custom class based onClick listerner
      var isClassBasedOnClickListenerScheme = false
      for listener in self.readerConfig.classBasedOnClickListeners {
        
        if scheme == listener.schemeName,
          let absoluteURLString = request.url?.absoluteString,
          let range = absoluteURLString.range(of: "/clientX=") {
          let baseURL = String(absoluteURLString[..<range.lowerBound])
          let positionString = String(absoluteURLString[range.lowerBound...])
          if let point = getEventTouchPoint(fromPositionParameterString: positionString) {
            let attributeContentString = (baseURL.replacingOccurrences(of: "\(scheme)://", with: "").removingPercentEncoding)
            // Call the on click action block
            listener.onClickAction(attributeContentString, point)
            // Mark the scheme as class based click listener scheme
            isClassBasedOnClickListenerScheme = true
          }
        }
      }
      
      if isClassBasedOnClickListenerScheme == false {
        // Try to open the url with the system if it wasn't a custom class based click listener
        if UIApplication.shared.canOpenURL(url) {
          UIApplication.shared.openURL(url)
          return false
        }
      } else {
        return false
      }
    }
    
    return true
  }
  
  fileprivate func getEventTouchPoint(fromPositionParameterString positionParameterString: String) -> CGPoint? {
    // Remove the parameter names: "/clientX=188&clientY=292" -> "188&292"
    var positionParameterString = positionParameterString.replacingOccurrences(of: "/clientX=", with: "")
    positionParameterString = positionParameterString.replacingOccurrences(of: "clientY=", with: "")
    // Separate both position values into an array: "188&292" -> [188],[292]
    let positionStringValues = positionParameterString.components(separatedBy: "&")
    // Multiply the raw positions with the screen scale and return them as CGPoint
    if
      positionStringValues.count == 2,
      let xPos = Int(positionStringValues[0]),
      let yPos = Int(positionStringValues[1]) {
      return CGPoint(x: xPos, y: yPos)
    }
    return nil
  }
  
  // MARK: Gesture recognizer
  
  open func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    true
  }
  
  public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    if gestureRecognizer == oneTapGesture && otherGestureRecognizer == twoTapsGesture {
      return true
    }
    if otherGestureRecognizer == twoTapsGesture, let tapGesture = gestureRecognizer as? UITapGestureRecognizer, tapGesture.numberOfTapsRequired == 2 {
      return true
    }
    return false
  }
  
  @objc open func handleTapGesture(_ recognizer: UITapGestureRecognizer) {
    let state = recognizer.state
    guard state != .cancelled || state != .failed else { return }
    self.webView?.js("resetSelectionText()")
    self.webView?.js("resetSelectedSentenceId()")
    self.webView?.js("removeSentenceHighlight()")
    self.webView?.js("removeThisHighlight()")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      self.handleOneTap(recognizer: recognizer)
    }
  }
  
  private func handleOneTap(recognizer: UITapGestureRecognizer) {
    let xString = webView?.js("getHighlightX()")
    let yString = webView?.js("getHighlightY()")
    guard let xStr = xString, let yStr = yString,
      let x = Int(xStr), let y = Int(yStr) else { return }
    let point = CGPoint(x: x, y: y)
    let prefix = "sentence-"
    if let word = webView?.js("getElementOnTap()") {
      delegate?.pageDidTap?(at: point, withSelectedWord: word)
    } else if let sentenceID = webView?.js("getSelectedSentenceOnTap()"),
      sentenceID.hasPrefix(prefix), let index = Int(String(sentenceID.dropFirst(prefix.count))) {
      delegate?.pageDidTap?(at: point, withSelectedSentence: sentences[index])
    }
  }
  
  @objc private func handleTwoTaps(_ recognizer: UITapGestureRecognizer) {
    if let _navigationController = self.folioReader.readerCenter?.navigationController, (_navigationController.isNavigationBarHidden == true) {
      if (self.shouldShowBar == true && self.menuIsVisible == false) {
        self.folioReader.readerCenter?.toggleBars()
      }
    } else if (self.readerConfig.shouldHideNavigationOnTap == true) {
      self.folioReader.readerCenter?.hideBars()
      self.menuIsVisible = false
    }
  }
  
  // MARK: - Public scroll postion setter
  
  /**
   Scrolls the page to a given offset
   
   - parameter offset:   The offset to scroll
   - parameter animated: Enable or not scrolling animation
   */
  open func scrollPageToOffset(_ offset: CGFloat, animated: Bool) {
    let pageOffsetPoint = self.readerConfig.isDirection(CGPoint(x: 0, y: offset), CGPoint(x: offset, y: 0), CGPoint(x: 0, y: offset))
    webView?.scrollView.setContentOffset(pageOffsetPoint, animated: animated)
  }
  
  /**
   Scrolls the page to bottom
   */
  open func scrollPageToBottom() {
    guard let webView = webView else { return }
    let bottomOffset = self.readerConfig.isDirection(
      CGPoint(x: 0, y: webView.scrollView.contentSize.height - webView.scrollView.bounds.height),
      CGPoint(x: webView.scrollView.contentSize.width - webView.scrollView.bounds.width, y: 0),
      CGPoint(x: webView.scrollView.contentSize.width - webView.scrollView.bounds.width, y: 0)
    )
    
    if bottomOffset.forDirection(withConfiguration: self.readerConfig) >= 0 {
      DispatchQueue.main.async {
        self.webView?.scrollView.setContentOffset(bottomOffset, animated: false)
      }
    }
  }
  
  /**
   Handdle #anchors in html, get the offset and scroll to it
   
   - parameter anchor:                The #anchor
   - parameter avoidBeginningAnchors: Sometimes the anchor is on the beggining of the text, there is not need to scroll
   - parameter animated:              Enable or not scrolling animation
   */
  open func handleAnchor(_ anchor: String,  avoidBeginningAnchors: Bool, animated: Bool) {
    if !anchor.isEmpty {
      let offset = getAnchorOffset(anchor)
      
      switch self.readerConfig.scrollDirection {
      case .vertical, .defaultVertical:
        let isBeginning = (offset < frame.forDirection(withConfiguration: self.readerConfig) * 0.5)
        
        if !avoidBeginningAnchors {
          scrollPageToOffset(offset, animated: animated)
        } else if avoidBeginningAnchors && !isBeginning {
          scrollPageToOffset(offset, animated: animated)
        }
      case .horizontal, .horizontalWithVerticalContent:
        scrollPageToOffset(offset, animated: animated)
      }
    }
  }
  
  // MARK: Helper
  
  /**
   Get the #anchor offset in the page
   
   - parameter anchor: The #anchor id
   - returns: The element offset ready to scroll
   */
  func getAnchorOffset(_ anchor: String) -> CGFloat {
    let horizontal = self.readerConfig.scrollDirection == .horizontal
    if let strOffset = webView?.js("getAnchorOffset('\(anchor)', \(horizontal.description))") {
      return CGFloat((strOffset as NSString).floatValue)
    }
    
    return CGFloat(0)
  }
  
  // MARK: Mark ID
  
  /**
   Audio Mark ID - marks an element with an ID with the given class and scrolls to it
   
   - parameter identifier: The identifier
   */
  func audioMarkID(_ identifier: String) {
    guard let currentPage = self.folioReader.readerCenter?.currentPage else {
      return
    }
    
    let playbackActiveClass = self.book.playbackActiveClass
    currentPage.webView?.js("audioMarkID('\(playbackActiveClass)','\(identifier)')")
  }
  
  // MARK: UIMenu visibility
  
  override open func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    return false
  }
  
  // MARK: ColorView fix for horizontal layout
  @objc func refreshPageMode() {
    guard let webView = webView else { return }
    
    if (self.folioReader.nightMode == true) {
      // omit create webView and colorView
      let script = "document.documentElement.offsetHeight"
      let contentHeight = webView.stringByEvaluatingJavaScript(from: script)
      let frameHeight = webView.frame.height
      let lastPageHeight = frameHeight * CGFloat(webView.pageCount) - CGFloat(Double(contentHeight!)!)
      colorView.frame = CGRect(x: webView.frame.width * CGFloat(webView.pageCount-1), y: webView.frame.height - lastPageHeight, width: webView.frame.width, height: lastPageHeight)
    } else {
      colorView.frame = CGRect.zero
    }
  }
  
  // MARK: - Class based click listener
  
  fileprivate func setupClassBasedOnClickListeners() {
    for listener in self.readerConfig.classBasedOnClickListeners {
      self.webView?.js("addClassBasedOnClickListener(\"\(listener.schemeName)\", \"\(listener.querySelector)\", \"\(listener.attributeName)\", \"\(listener.selectAll)\")");
    }
  }
  
  // MARK: - Public Java Script injection
  
  /**
   Runs a JavaScript script and returns it result. The result of running the JavaScript script passed in the script parameter, or nil if the script fails.
   
   - returns: The result of running the JavaScript script passed in the script parameter, or nil if the script fails.
   */
  open func performJavaScript(_ javaScriptCode: String) -> String? {
    return webView?.js(javaScriptCode)
  }
}
