/**
 * LoginForm —— 账号密码登录表单（AuthPage 与服务端编辑弹层共用）
 *
 * 只负责输入 UI：用户名 / 密码 / 记住密码 + 安全说明。
 * 登录按钮和错误提示由宿主页面放置（两处按钮语义不同：
 * AuthPage 是「登录」，编辑弹层是「保存并切换」）。
 *
 * 2FA 输入已按产品决策移除（2026-09-06）：默认只支持账号密码登录；
 * 开启 2FA 的账号登录时服务端会返回错误，由宿主展示错误信息。
 * AuthService.login 的 2FA 参数仍保留（传空串），未来要恢复只是加回一个输入框。
 */

@Component
export struct LoginForm {
  @Link username: string;
  @Link password: string;
  @Link remember: boolean;

  build() {
    Column({ space: 10 }) {
      TextInput({ text: this.username, placeholder: '用户名' })
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .onChange((v: string): void => {
          this.username = v;
        })

      TextInput({ text: this.password, placeholder: '密码' })
        .type(InputType.Password)
        .height(44)
        .fontSize(15)
        .backgroundColor($r('app.color.card_bg'))
        .onChange((v: string): void => {
          this.password = v;
        })

      Row({ space: 8 }) {
        Toggle({ type: ToggleType.Checkbox, isOn: this.remember })
          .onChange((on: boolean): void => {
            this.remember = on;
          })
        Text('记住密码，会话过期后自动重新登录')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')

      Text('勾选后，密码加密保存在手机系统安全存储中，仅本应用可读，不会上传到任何服务器；只用于会话过期后自动重新登录，取消勾选会立即从本机删除已保存的密码。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
    }
    .width('100%')
  }
}
